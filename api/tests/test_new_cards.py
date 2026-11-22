"""Spec 021: the daily cap on new cards (rolling 24 h, one per note), its setting and migration."""

import sqlite3
from datetime import UTC, datetime, timedelta

import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import (
    Card,
    CardRead,
    Direction,
    NoteCreate,
    NoteType,
    Rating,
    ReportCreate,
    ReportReason,
)

T0 = datetime(2026, 11, 1, 8, tzinfo=UTC)
DAY = deck.NEW_CARD_WINDOW
SECOND = timedelta(seconds=1)


@pytest.fixture
def anyio_backend():
    return "asyncio"


def _add(session, count: int, now=T0, prefix="w") -> list[CardRead]:
    """`count` one-card basic notes, one second apart (the oldest first)."""
    cards = []
    for i in range(count):
        note = NoteCreate(type=NoteType.basic, fields={"front": f"{prefix}{i}", "back": "x"})
        [added] = deck.add_notes(session, [note], now=now + i * SECOND).added
        cards.append(deck.get_card(session, added.cards[0].id))
    return cards


def _queue(session, now) -> list:
    return [c.id for c in deck.due_cards(session, limit=200, now=now)]


def _new_in_queue(session, now) -> list:
    return [c.id for c in deck.due_cards(session, limit=200, now=now) if c.state == "new"]


def _review(session, cards, now, rating=Rating.easy) -> None:
    for card in cards:
        deck.review_card(session, card.id, rating, now=now)


def _ids(cards) -> list:
    return [c.id for c in cards]


# --- 1, 2: the cap and the rolling window --------------------------------------------------------


def test_1_fresh_deck_lets_the_15_oldest_new_cards_in(session):
    assert deck.get_settings(session).new_cards_per_day == 15
    cards = _add(session, 20)
    now = T0 + timedelta(minutes=1)

    assert _queue(session, now) == _ids(cards[:15])
    stats = deck.agent_stats(session, now)
    assert (stats.due, stats.new) == (15, 20)
    assert stats.new_cards.model_dump() == {
        "per_day": 15, "introduced": 0, "available": 15, "waiting": 5, "days": 1,
    }  # fmt: skip


def test_1_a_batch_added_in_one_call_comes_in_in_the_order_given(session):
    notes = [
        NoteCreate(type=NoteType.basic, fields={"front": f"w{i}", "back": "x"}) for i in range(20)
    ]
    deck.add_notes(session, notes, now=T0)  # one `created_at` for all

    fronts = [c.front for c in deck.due_cards(session, limit=200, now=T0)]
    assert fronts == [f"w{i}" for i in range(15)]


def test_2_after_15_introductions_the_next_5_wait_24_hours(session):
    cards = _add(session, 20)
    t = T0 + timedelta(minutes=1)
    _review(session, cards[:15], t, Rating.good)  # learning: still in the queue

    assert _new_in_queue(session, t + timedelta(minutes=1)) == []
    assert _new_in_queue(session, t + DAY - SECOND) == []
    assert _new_in_queue(session, t + DAY + SECOND) == _ids(cards[15:])


# --- 3: started cards are never held -----------------------------------------------------------


def test_3_reviewed_cards_are_never_held_by_the_cap(session):
    [old] = _add(session, 1, now=T0 - timedelta(days=30), prefix="old")
    _review(session, [old], T0 - timedelta(days=30))
    row = session.get(Card, old.id)
    row.due = T0  # an old review card, due now
    session.add(row)
    session.commit()

    cards = _add(session, 17)
    t = T0 + timedelta(minutes=1)
    _review(session, cards[:14], t)
    _review(session, cards[14:15], t, Rating.again)  # a learning card from today
    learning = deck.get_card(session, cards[14].id)
    assert learning.state == "learning"

    now = learning.due + SECOND
    queue = _queue(session, now)
    assert old.id in queue and learning.id in queue
    assert _new_in_queue(session, now) == []
    assert deck.new_cards_status(session, now).waiting == 2


# --- 4, 5: one new card per note per day ---------------------------------------------------------


def _person(session, now, *prompts: str):
    note = NoteCreate(
        type=NoteType.person,
        fields={"photo": "https://example.org/p/1.jpg", "name": "Ada Example",
                "description": "runs the bakery"},
        directions=[Direction(prompt=[p]) for p in prompts],
    )  # fmt: skip
    [added] = deck.add_notes(session, [note], now=now).added
    return {card.prompt[0]: card for card in added.cards}


def test_4_a_notes_new_cards_arrive_on_different_days(session):
    cards = _person(session, T0, "description", "name", "photo")
    assert _queue(session, T0 + SECOND) == [cards["photo"].id]  # field order: photo first
    status = deck.new_cards_status(session, T0 + SECOND)
    assert (status.available, status.waiting) == (1, 2)

    t = T0 + timedelta(minutes=1)
    assert deck.review_card(session, cards["photo"].id, Rating.easy, now=t).due > t + 2 * DAY
    assert deck.stats(session, t + SECOND).next_due == t + DAY
    assert _queue(session, t + deck.SIBLING_BURY + SECOND) == []  # not the 6 h hold
    assert _queue(session, t + DAY - SECOND) == []
    assert _queue(session, t + DAY + SECOND) == [cards["name"].id]
    status = deck.new_cards_status(session, t + DAY + SECOND)
    assert (status.introduced, status.available, status.waiting) == (0, 1, 1)


def test_5_a_note_with_two_new_cards_lets_one_in(session):
    cards = _person(session, T0, "photo", "name")
    assert _queue(session, T0) == [cards["photo"].id]
    assert deck.new_cards_status(session, T0).waiting == 1


def test_5_a_new_direction_on_a_note_not_introduced_today_is_eligible_at_once(session):
    [card] = _add(session, 1)
    _review(session, [card], T0)
    later = T0 + DAY + timedelta(hours=1)

    note = deck.add_direction(session, card.note_id, Direction(prompt=["back"]), now=later)
    [reverse] = [c for c in note.cards if c.prompt == ["back"]]
    assert _queue(session, later) == [reverse.id]


# --- 6, 7: next_due stays truthful ---------------------------------------------------------------


def test_6_7_next_due_is_when_the_oldest_introduction_leaves_the_window(session):
    cards = _add(session, 20)
    t = T0 + timedelta(minutes=1)
    for i, card in enumerate(cards[:15]):
        deck.review_card(session, card.id, Rating.easy, now=t + i * SECOND)  # due in days

    stats = deck.stats(session, t + timedelta(hours=1))
    assert (stats.due, stats.next_due) == (0, t + DAY)
    assert _queue(session, stats.next_due) == [cards[15].id]  # 7: something is servable then


def test_6_paused_waiting_cards_never_set_next_due(session):
    _add(session, 3)
    deck.set_new_cards_per_day(session, 0)
    stats = deck.stats(session, T0 + SECOND)
    assert (stats.due, stats.new, stats.next_due) == (0, 3, None)

    [card] = _add(session, 1, prefix="seen")
    deck.set_new_cards_per_day(session, 1)
    reviewed = deck.review_card(session, card.id, Rating.easy, now=T0)
    deck.set_new_cards_per_day(session, 0)
    assert deck.stats(session, T0 + SECOND).next_due == reviewed.due  # other cards only


def test_7_next_due_waits_for_a_siblings_window_after_a_slot_frees(session):
    deck.set_new_cards_per_day(session, 3)
    early = T0 - timedelta(hours=1)
    first, second = _add(session, 2, now=early)
    cards = _person(session, early, "photo", "name")
    deck.review_card(session, first.id, Rating.easy, now=T0)
    deck.review_card(session, second.id, Rating.easy, now=T0 + timedelta(hours=1))
    deck.review_card(session, cards["photo"].id, Rating.easy, now=T0 + timedelta(hours=2))
    deck.set_new_cards_per_day(session, 2)

    # 3 introductions, cap 2: a slot frees when the 2nd oldest leaves the window (T0 + 25 h),
    # but the person's window ends only at T0 + 26 h.
    next_due = deck.stats(session, T0 + timedelta(hours=3)).next_due
    assert next_due == T0 + DAY + timedelta(hours=2)
    assert _queue(session, T0 + DAY + timedelta(hours=1) + SECOND) == []
    assert _queue(session, next_due) == [cards["name"].id]


# --- 8: changing the cap -----------------------------------------------------------------------


def test_8_lowering_holds_no_started_card_and_raising_lets_more_in_at_once(session):
    cards = _add(session, 40)
    t = T0 + timedelta(minutes=1)
    _review(session, cards[:15], t, Rating.good)  # 15 learning cards
    now = deck.get_card(session, cards[0].id).due + SECOND

    deck.set_new_cards_per_day(session, 5)
    assert _new_in_queue(session, now) == []
    assert set(_ids(cards[:15])) <= set(_queue(session, now))  # learning: all still there

    status = deck.set_new_cards_per_day(session, 30, now=now)
    assert (status.introduced, status.available, status.waiting) == (15, 15, 10)
    assert _new_in_queue(session, now) == _ids(cards[15:30])


# --- 10, 11, 12 ----------------------------------------------------------------------------------


def test_10_the_setting_persists(tmp_path):
    url = f"sqlite:///{tmp_path / 'deck.db'}"
    engine = make_engine(url)
    with Session(engine) as session:
        assert deck.set_new_cards_per_day(session, 7).per_day == 7
    engine.dispose()

    engine = make_engine(url)
    with Session(engine) as session:
        assert deck.get_settings(session).new_cards_per_day == 7
    engine.dispose()


def test_set_rejects_out_of_range_and_keeps_the_setting(session):
    deck.set_new_cards_per_day(session, 9)
    for value in (-1, 201):
        with pytest.raises(deck.InvalidSetting, match="between 0 and 200"):
            deck.set_new_cards_per_day(session, value)
    assert deck.get_settings(session).new_cards_per_day == 9
    assert deck.set_new_cards_per_day(session, 200).per_day == 200


def test_11_report_held_new_cards_take_no_slot_and_do_not_wait(session):
    cards = _add(session, 20)
    for card in cards[:3]:
        deck.report_card(session, card.id, ReportCreate(reason=ReportReason.wrong), now=T0)

    assert _queue(session, T0 + timedelta(minutes=1)) == _ids(cards[3:18])
    status = deck.new_cards_status(session, T0 + timedelta(minutes=1))
    assert (status.available, status.waiting) == (15, 2)


def test_12_deleting_an_introduced_card_does_not_free_its_slot(session):
    deck.set_new_cards_per_day(session, 2)
    cards = _add(session, 4)
    _review(session, cards[:2], T0 + timedelta(minutes=1))
    deck.delete_card(session, cards[0].id)

    status = deck.new_cards_status(session, T0 + timedelta(hours=1))
    assert (status.introduced, status.available, status.waiting) == (2, 0, 2)
    assert _new_in_queue(session, T0 + timedelta(hours=1)) == []


# --- 14: REST is unchanged -----------------------------------------------------------------------


def test_14_rest_stats_keeps_its_shape_and_follows_the_cap(client):
    for i in range(20):
        assert client.post("/cards", json={"front": f"w{i}", "back": "x"}).status_code == 201

    stats = client.get("/stats").json()
    assert set(stats) == {"total", "due", "new", "reviewed_today", "next_due", "streak"}
    due = client.get("/cards/due", params={"limit": 200}).json()
    assert (stats["due"], stats["new"], len(due)) == (15, 20, 15)
    assert [c["front"] for c in due] == [f"w{i}" for i in range(15)]


# --- 15: migration 021 ---------------------------------------------------------------------------


def _tables(path) -> list[str]:
    db = sqlite3.connect(path)
    tables = sorted(r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'"))
    db.close()
    return tables


def test_15_migration_creates_the_settings_table_once_with_a_backup(tmp_path):
    path = tmp_path / "deck.db"
    url = f"sqlite:///{path}"
    engine = make_engine(url)  # a current deck...
    with Session(engine) as session:
        [card] = _add(session, 1)
    engine.dispose()
    db = sqlite3.connect(path)
    db.execute("DROP TABLE settings")  # ...as it was before spec 021
    db.commit()
    db.close()
    assert list(tmp_path.glob("*.bak")) == []

    make_engine(url).dispose()

    assert "settings" in _tables(path)
    [backup] = tmp_path.glob("deck.db.pre-021-*.bak")
    assert "settings" not in _tables(backup)
    with Session(make_engine(url)) as session:  # the deck is intact, the defaults apply
        assert deck.get_card(session, card.id).front == "w0"
        assert deck.get_settings(session).new_cards_per_day == 15
    assert len(list(tmp_path.glob("*.bak"))) == 1  # the second start changed nothing


def test_15_a_fresh_database_gets_the_table_without_a_backup(tmp_path):
    make_engine(f"sqlite:///{tmp_path / 'deck.db'}").dispose()
    assert "settings" in _tables(tmp_path / "deck.db")
    assert list(tmp_path.glob("*.bak")) == []


# --- MCP: 1, 9, 13, 16 ---------------------------------------------------------------------------

BASIC = [{"type": "basic", "fields": {"front": f"w{i}", "back": "x"}} for i in range(60)]


@pytest.mark.anyio
async def test_9_new_cards_per_day_reads_sets_and_rejects_out_of_range(engine):
    async with Client(build_mcp(engine)) as client:
        read = await client.call_tool("new_cards_per_day", {})
        assert read.structured_content["per_day"] == 15  # criterion 1

        await client.call_tool("add_notes", {"notes": BASIC[:3]})
        paused = await client.call_tool("new_cards_per_day", {"value": 0})
        assert paused.structured_content == {
            "per_day": 0, "introduced": 0, "available": 0, "waiting": 3, "days": None,
        }  # fmt: skip
        due = await client.call_tool("due_cards", {"limit": 200})
        assert due.structured_content["result"] == []

        for value in (201, -1):
            bad = await client.call_tool("new_cards_per_day", {"value": value})
            assert bad.is_error
            assert bad.content[0].text.endswith(
                "new_cards_per_day must be between 0 and 200 (0 pauses new cards)."
            )  # after the SDK's "Error executing tool …: " prefix
        read = await client.call_tool("new_cards_per_day", {})
        assert read.structured_content["per_day"] == 0

        [tool] = [t for t in (await client.list_tools()).tools if t.name == "new_cards_per_day"]
        assert "Change it only when the user asks" in tool.description


@pytest.mark.anyio
async def test_13_add_notes_and_add_cards_report_the_cap(engine):
    async with Client(build_mcp(engine)) as client:
        added = await client.call_tool("add_notes", {"notes": BASIC})
        assert len(added.structured_content["added"]) == 60
        assert added.structured_content["new_cards"] == {
            "per_day": 15, "introduced": 0, "available": 15, "waiting": 45, "days": 3,
        }  # fmt: skip

        cards = await client.call_tool("add_cards", {"cards": [{"front": "chat", "back": "cat"}]})
        assert cards.structured_content["new_cards"]["waiting"] == 46
        assert len(cards.structured_content["added"]) == 1

        stats = (await client.call_tool("deck_stats", {})).structured_content
        assert (stats["due"], stats["new"], stats["new_cards"]["days"]) == (15, 61, 4)


@pytest.mark.anyio
async def test_16_instructions_and_add_notes_docstring_mention_the_cap(engine):
    assert "new_cards_per_day" in INSTRUCTIONS
    assert "only when the user asks" in INSTRUCTIONS
    async with Client(build_mcp(engine)) as client:
        tools = {t.name: t.description for t in (await client.list_tools()).tools}
    assert "daily new-card cap" in tools["add_notes"]
    assert "daily new-card cap" in tools["add_cards"]
