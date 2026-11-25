"""Spec 021 v3: new cards are never held back; the stored setting is the size M of the new-card
steps the app shows (MCP `new_card_milestone`). The ladder counts are in `test_ladder.py`."""

import sqlite3
from datetime import UTC, datetime, timedelta

import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import CardRead, Direction, NoteCreate, NoteType, Rating, Settings

T0 = datetime(2026, 11, 1, 8, tzinfo=UTC)
SECOND = timedelta(seconds=1)
ONE_WAY = Direction(prompt=["front"], answer=["back"])


@pytest.fixture
def anyio_backend():
    return "asyncio"


def _add(session, count: int, now=T0, prefix="w") -> list[CardRead]:
    """`count` one-card basic notes, one second apart (the oldest first)."""
    cards = []
    for i in range(count):
        note = NoteCreate(
            type=NoteType.basic, fields={"front": f"{prefix}{i}", "back": "x"}, directions=[ONE_WAY]
        )
        [added] = deck.add_notes(session, [note], now=now + i * SECOND).added
        cards.append(deck.get_card(session, added.cards[0].id))
    return cards


def _new_in_queue(session, now) -> list:
    return [c.id for c in deck.due_cards(session, limit=200, now=now) if c.state == "new"]


def _review(session, cards, now, rating=Rating.easy) -> None:
    for card in cards:
        deck.review_card(session, card.id, rating, now=now)


# --- Nothing is held back (AC 1) ---------------------------------------------------------------


def test_every_new_card_is_served_and_stays_servable(session):
    cards = _add(session, 60)
    now = T0 + timedelta(minutes=1)
    assert _new_in_queue(session, now) == [c.id for c in cards]
    assert (deck.stats(session, now).due, deck.stats(session, now).new) == (60, 60)

    _review(session, cards[:15], now)
    later = now + timedelta(minutes=1)
    assert _new_in_queue(session, later) == [c.id for c in cards[15:]]


# --- The setting -------------------------------------------------------------------------------


def test_the_milestone_persists_across_engines(tmp_path):
    url = f"sqlite:///{tmp_path / 'deck.db'}"
    engine = make_engine(url)
    with Session(engine) as session:
        assert deck.get_milestone(session) == 15
        assert deck.set_milestone(session, 7) == 7
    engine.dispose()

    engine = make_engine(url)
    with Session(engine) as session:
        assert deck.get_milestone(session) == deck.stats(session).milestone == 7
    engine.dispose()


def test_set_milestone_rejects_out_of_range_and_keeps_the_setting(session):
    deck.set_milestone(session, 9)
    for value in (0, -1, 201):
        with pytest.raises(deck.InvalidSetting, match="between 1 and 200"):
            deck.set_milestone(session, value)
    assert deck.get_milestone(session) == 9
    assert deck.set_milestone(session, 200) == 200


def test_a_stored_zero_reads_as_15(session):
    session.add(Settings(new_cards_per_day=0))  # possible under the v2 range (0-200)
    session.commit()
    assert deck.get_milestone(session) == deck.stats(session).milestone == 15


# --- REST (AC 11) ------------------------------------------------------------------------------


def test_rest_stats_has_024s_keys_plus_the_ladder_counts(client):
    stats = client.get("/stats").json()
    assert set(stats) == {
        *("total", "due", "new", "reviewed_today", "next_due", "streak"),
        *("new_today", "milestone", "streak_start", "history_start", "history", "due_new"),
        *("at_risk_total", "at_risk_done", "reviews_total", "reviews_done"),
    }
    ladder = ("at_risk_total", "at_risk_done", "reviews_total", "reviews_done", "milestone")
    assert [stats[k] for k in ladder] == [0, 0, 0, 0, 15]

    for i in range(20):
        assert client.post("/cards", json={"front": f"w{i}", "back": "x"}).status_code == 201
    stats = client.get("/stats").json()
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
        assert deck.get_milestone(session) == 15
    assert len(list(tmp_path.glob("*.bak"))) == 1  # the second start changed nothing


def test_a_fresh_database_gets_the_table_without_a_backup(tmp_path):
    make_engine(f"sqlite:///{tmp_path / 'deck.db'}").dispose()
    assert "settings" in _tables(tmp_path / "deck.db")
    assert list(tmp_path.glob("*.bak")) == []


# --- MCP (AC 12) -------------------------------------------------------------------------------

BASIC = [{"type": "basic", "fields": {"front": f"w{i}", "back": "x"}} for i in range(60)]


@pytest.mark.anyio
async def test_new_card_milestone_reads_sets_and_rejects_out_of_range(client):
    async with Client(build_mcp(client.app.state.engine)) as mcp:
        read = await mcp.call_tool("new_card_milestone", {})
        assert read.structured_content == {"milestone": 15}
        five = await mcp.call_tool("new_card_milestone", {"value": 5})
        assert five.structured_content == {"milestone": 5}
        stats = (await mcp.call_tool("deck_stats", {})).structured_content
        assert stats["milestone"] == client.get("/stats").json()["milestone"] == 5

        for value in (0, 201, -1):
            bad = await mcp.call_tool("new_card_milestone", {"value": value})
            assert bad.is_error
            assert bad.content[0].text.endswith("new_card_milestone must be between 1 and 200.")
        assert (await mcp.call_tool("new_card_milestone", {})).structured_content == {
            "milestone": 5
        }

        tools = {t.name: t.description for t in (await mcp.list_tools()).tools}
    assert "new_cards_per_day" not in tools
    assert "never held back" in tools["new_card_milestone"]
    assert "only when the user asks" in tools["new_card_milestone"]


@pytest.mark.anyio
async def test_add_notes_and_add_cards_reply_new_and_milestone(engine):
    async with Client(build_mcp(engine)) as client:
        added = (await client.call_tool("add_notes", {"notes": BASIC})).structured_content
        assert len(added["added"]) == 60
        assert (added["new"], added["milestone"]) == (120, 15)  # spec 026: both directions
        assert "new_cards" not in added

        cards = await client.call_tool("add_cards", {"cards": [{"front": "chat", "back": "cat"}]})
        assert (cards.structured_content["new"], cards.structured_content["milestone"]) == (121, 15)
        assert "new_cards" not in cards.structured_content


@pytest.mark.anyio
async def test_no_text_says_reviews_are_a_daily_must(engine):
    assert "never held back" in INSTRUCTIONS
    assert "new_card_milestone" in INSTRUCTIONS
    async with Client(build_mcp(engine)) as client:
        tools = {t.name: t.description for t in (await client.list_tools()).tools}
        prompts = (await client.list_prompts()).prompts
    for text in [INSTRUCTIONS, *tools.values(), *(p.description or "" for p in prompts)]:
        lowered = text.lower()
        for phrase in ("must review", "every day", "daily work", "daily target", "each day"):
            assert phrase not in lowered
    assert "New cards are due at once, after due reviews." in tools["add_notes"]
    assert "New cards are due at once, after due reviews." in tools["add_cards"]
    assert "display only, nothing is held back" in tools["deck_stats"]
