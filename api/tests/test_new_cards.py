"""Spec 021 as hotfixed (user decision 2026-11-22): `new_cards_per_day` is a daily target, not a
limit. Every new card stays servable; the setting, its migration and the counters remain."""

import sqlite3
from datetime import UTC, datetime, timedelta

import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import CardRead, NoteCreate, NoteType, Rating, ReportCreate, ReportReason

T0 = datetime(2026, 11, 1, 8, tzinfo=UTC)
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


def _new_in_queue(session, now) -> list:
    return [c.id for c in deck.due_cards(session, limit=200, now=now) if c.state == "new"]


def _review(session, cards, now, rating=Rating.easy) -> None:
    for card in cards:
        deck.review_card(session, card.id, rating, now=now)


# --- Nothing is held back ----------------------------------------------------------------------


def test_every_new_card_is_served_beyond_the_target(session):
    assert deck.get_settings(session).new_cards_per_day == 15
    cards = _add(session, 20)
    now = T0 + timedelta(minutes=1)

    assert _new_in_queue(session, now) == [c.id for c in cards]
    stats = deck.agent_stats(session, now)
    assert (stats.due, stats.new) == (20, 20)
    assert stats.new_cards.model_dump() == {
        "per_day": 15, "introduced": 0, "available": 15, "waiting": 5, "days": 1,
    }  # fmt: skip


def test_new_cards_stay_served_after_the_target_is_reached_and_at_zero(session):
    cards = _add(session, 20)
    t = T0 + timedelta(minutes=1)
    _review(session, cards[:15], t)

    now = t + timedelta(minutes=1)
    assert _new_in_queue(session, now) == [c.id for c in cards[15:]]
    status = deck.new_cards_status(session, now)
    assert (status.introduced, status.available, status.waiting, status.days) == (15, 0, 5, 1)

    deck.set_new_cards_per_day(session, 0)
    assert _new_in_queue(session, now) == [c.id for c in cards[15:]]
    assert deck.new_cards_status(session, now).days is None


def test_introductions_count_from_the_review_log_in_a_rolling_24_h(session):
    cards = _add(session, 4)
    _review(session, cards[:2], T0)
    deck.delete_card(session, cards[0].id)  # its first review still counts

    assert deck.new_cards_status(session, T0 + timedelta(hours=23)).introduced == 2
    assert deck.new_cards_status(session, T0 + deck.NEW_CARD_WINDOW).introduced == 0


def test_report_held_new_cards_are_not_counted(session):
    cards = _add(session, 20)
    for card in cards[:3]:
        deck.report_card(session, card.id, ReportCreate(reason=ReportReason.wrong), now=T0)
    status = deck.new_cards_status(session, T0)
    assert (status.available, status.waiting) == (15, 2)


# --- The setting -------------------------------------------------------------------------------


def test_the_setting_persists(tmp_path):
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


# --- REST is unchanged -------------------------------------------------------------------------


def test_rest_stats_keeps_its_shape_and_serves_every_new_card(client):
    for i in range(20):
        assert client.post("/cards", json={"front": f"w{i}", "back": "x"}).status_code == 201

    stats = client.get("/stats").json()
    assert set(stats) == {"total", "due", "new", "reviewed_today", "next_due", "streak"}
    due = client.get("/cards/due", params={"limit": 200}).json()
    assert (stats["due"], stats["new"], len(due)) == (20, 20, 20)


# --- Migration 021 -----------------------------------------------------------------------------


def _tables(path) -> list[str]:
    db = sqlite3.connect(path)
    tables = sorted(r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'"))
    db.close()
    return tables


def test_migration_creates_the_settings_table_once_with_a_backup(tmp_path):
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


def test_a_fresh_database_gets_the_table_without_a_backup(tmp_path):
    make_engine(f"sqlite:///{tmp_path / 'deck.db'}").dispose()
    assert "settings" in _tables(tmp_path / "deck.db")
    assert list(tmp_path.glob("*.bak")) == []


# --- MCP ---------------------------------------------------------------------------------------

BASIC = [{"type": "basic", "fields": {"front": f"w{i}", "back": "x"}} for i in range(60)]


@pytest.mark.anyio
async def test_new_cards_per_day_reads_sets_and_rejects_out_of_range(engine):
    async with Client(build_mcp(engine)) as client:
        read = await client.call_tool("new_cards_per_day", {})
        assert read.structured_content["per_day"] == 15

        await client.call_tool("add_notes", {"notes": BASIC[:3]})
        zero = await client.call_tool("new_cards_per_day", {"value": 0})
        assert zero.structured_content == {
            "per_day": 0, "introduced": 0, "available": 0, "waiting": 3, "days": None,
        }  # fmt: skip
        due = await client.call_tool("due_cards", {"limit": 200})
        assert len(due.structured_content["result"]) == 3  # a target, not a limit

        for value in (201, -1):
            bad = await client.call_tool("new_cards_per_day", {"value": value})
            assert bad.is_error
            assert bad.content[0].text.endswith("new_cards_per_day must be between 0 and 200.")
        read = await client.call_tool("new_cards_per_day", {})
        assert read.structured_content["per_day"] == 0

        [tool] = [t for t in (await client.list_tools()).tools if t.name == "new_cards_per_day"]
        assert "not a limit" in tool.description
        assert "only when the" in tool.description


@pytest.mark.anyio
async def test_add_notes_and_add_cards_report_the_target(engine):
    async with Client(build_mcp(engine)) as client:
        added = await client.call_tool("add_notes", {"notes": BASIC})
        assert len(added.structured_content["added"]) == 60
        assert added.structured_content["new_cards"] == {
            "per_day": 15, "introduced": 0, "available": 15, "waiting": 45, "days": 3,
        }  # fmt: skip

        cards = await client.call_tool("add_cards", {"cards": [{"front": "chat", "back": "cat"}]})
        assert cards.structured_content["new_cards"]["waiting"] == 46

        stats = (await client.call_tool("deck_stats", {})).structured_content
        assert (stats["due"], stats["new"], stats["new_cards"]["days"]) == (61, 61, 4)


@pytest.mark.anyio
async def test_instructions_say_the_number_is_a_target(engine):
    assert "new_cards_per_day" in INSTRUCTIONS
    assert "not a limit" in INSTRUCTIONS
    assert "only when the user asks" in INSTRUCTIONS
    async with Client(build_mcp(engine)) as client:
        tools = {t.name: t.description for t in (await client.list_tools()).tools}
    assert "not a limit" in tools["add_notes"]
    assert "cap" not in tools["due_cards"]
