"""Spec 031: MCP `review_history` and `struggling_cards` over `ReviewLog`."""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from mcp import Client
from sqlmodel import Session, func, select

from la_carte_api import deck
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import (
    ActivityEvent,
    Card,
    Direction,
    NoteCreate,
    NoteRead,
    Rating,
    ReviewLog,
)

pytestmark = pytest.mark.anyio

T0 = datetime(2026, 11, 1, tzinfo=UTC)
ONE_WAY = [Direction(prompt=["front"])]


@pytest.fixture
def anyio_backend():
    return "asyncio"


def _note(session: Session, front: str, both: bool = False) -> NoteRead:
    fields = {"front": front, "back": f"{front} answer"}
    note = NoteCreate(type="basic", fields=fields, directions=None if both else ONE_WAY)
    [added] = deck.add_notes(session, [note]).added
    return added


def _card(session: Session, front: str) -> UUID:
    return _note(session, front).cards[0].id


def _review(session: Session, card_id: UUID, rating: str, hours: float) -> None:
    deck.review_card(session, card_id, Rating(rating), now=T0 + timedelta(hours=hours))


async def _call(engine, tool: str, **arguments) -> list[dict]:
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool(tool, arguments)
    assert not result.is_error, result.content
    return result.structured_content["result"]


async def _fails(engine, tool: str, **arguments) -> bool:
    async with Client(build_mcp(engine)) as client:
        return (await client.call_tool(tool, arguments)).is_error


# --- review_history --------------------------------------------------------------------------


async def test_history_lists_app_and_agent_ratings_newest_first_with_the_card(client):
    engine = client.app.state.engine
    with Session(engine) as session:
        note = _note(session, "chat")
    card_id = str(note.cards[0].id)
    async with Client(build_mcp(engine)) as mcp:
        await mcp.call_tool("review_card", {"card_id": card_id, "rating": "good"})
        assert client.post(f"/cards/{card_id}/review", json={"rating": "again"}).is_success
        rated = {"card_id": card_id, "rating": "easy", "confidence": 0.8}
        await mcp.call_tool("review_card", rated)

    entries = await _call(engine, "review_history")
    assert [(e["rating"], e["confidence"]) for e in entries] == [
        ("easy", 0.8),
        ("again", None),
        ("good", None),
    ]
    times = [datetime.fromisoformat(e["reviewed_at"]) for e in entries]
    assert times == sorted(times, reverse=True)
    assert all(t.utcoffset() == timedelta(0) for t in times)
    for entry in entries:
        assert entry["card_id"] == card_id
        card = entry["card"]
        assert (card["front"], card["back"], card["note_id"]) == (
            "chat",
            "chat answer",
            str(note.id),
        )


async def test_history_filters_by_card_note_and_rating(engine):
    with Session(engine) as session:
        both = _note(session, "chat", both=True)
        forward, reverse = (card.id for card in both.cards)
        other = _card(session, "chien")
        _review(session, forward, "again", 1)
        _review(session, reverse, "good", 2)
        _review(session, other, "again", 3)

    by_card = await _call(engine, "review_history", card_id=str(forward))
    assert [e["card_id"] for e in by_card] == [str(forward)]

    by_note = await _call(engine, "review_history", note_id=str(both.id))
    assert [e["card_id"] for e in by_note] == [str(reverse), str(forward)]

    fails = await _call(engine, "review_history", rating="again")
    assert [e["card_id"] for e in fails] == [str(other), str(forward)]

    both_ids = await _call(engine, "review_history", card_id=str(other), note_id=str(both.id))
    assert both_ids == []


async def test_history_window_since_inclusive_until_exclusive(engine):
    at = datetime(2026, 11, 24, 23, tzinfo=UTC)  # = 2026-11-25T00:00:00+01:00
    with Session(engine) as session:
        card_id = _card(session, "chat")
        deck.review_card(session, card_id, Rating.good, now=at - timedelta(hours=1))
        deck.review_card(session, card_id, Rating.good, now=at)
        deck.review_card(session, card_id, Rating.good, now=at + timedelta(hours=1))

    def hours(entries: list[dict]) -> list[int]:
        return [datetime.fromisoformat(e["reviewed_at"]).hour for e in entries]

    paris = "2026-11-25T00:00:00+01:00"
    assert hours(await _call(engine, "review_history", since=paris)) == [0, 23]
    assert hours(await _call(engine, "review_history", until=paris)) == [22]
    naive = "2026-11-24T23:00:00"
    assert hours(await _call(engine, "review_history", since=naive)) == [0, 23]
    assert hours(await _call(engine, "review_history", since="2026-11-24T23:00:00Z")) == [0, 23]
    one_hour = {"since": naive, "until": "2026-11-25T00:00:00Z"}
    assert hours(await _call(engine, "review_history", **one_hour)) == [23]
    backwards = {"since": "2026-11-26T00:00:00Z", "until": "2026-11-20T00:00:00Z"}
    assert await _call(engine, "review_history", **backwards) == []


async def test_history_keeps_a_removed_cards_entries_with_card_null(engine):
    with Session(engine) as session:
        both = _note(session, "chat", both=True)
        removed, kept = (card.id for card in both.cards)
        _review(session, removed, "again", 1)
        _review(session, kept, "good", 2)
        deck.remove_direction(session, removed)

    entries = await _call(engine, "review_history")
    assert [(e["card_id"], e["card"] is None) for e in entries] == [
        (str(kept), False),
        (str(removed), True),
    ]
    [by_card] = await _call(engine, "review_history", card_id=str(removed))
    assert by_card["card"] is None and by_card["rating"] == "again"
    # note_id covers the note's current cards only
    by_note = await _call(engine, "review_history", note_id=str(both.id))
    assert [e["card_id"] for e in by_note] == [str(kept)]

    unknown = str(uuid4())
    assert await _call(engine, "review_history", card_id=unknown) == []
    assert await _call(engine, "review_history", note_id=unknown) == []


async def test_history_limit_defaults_to_100_and_is_bounded(engine):
    with Session(engine) as session:
        card_id = _card(session, "chat")
        for minute in range(101):
            _review(session, card_id, "good", minute / 60)

    entries = await _call(engine, "review_history")
    assert len(entries) == 100
    oldest = datetime.fromisoformat(entries[-1]["reviewed_at"])
    assert oldest == T0 + timedelta(minutes=1)  # the 100 newest
    assert len(await _call(engine, "review_history", limit=1000)) == 101
    assert await _fails(engine, "review_history", limit=0)
    assert await _fails(engine, "review_history", limit=1001)


async def test_history_is_never_pruned(engine):
    long_ago = datetime.now(UTC) - timedelta(days=200)
    with Session(engine) as session:
        card_id = _card(session, "chat")
        deck.review_card(session, card_id, Rating.good, now=long_ago)
        deck.prune_activity(session)

    [entry] = await _call(engine, "review_history")
    assert datetime.fromisoformat(entry["reviewed_at"]) == long_ago


# --- struggling_cards ------------------------------------------------------------------------


def _seed_struggles(session: Session) -> dict[str, UUID]:
    """X 4 reviews / 3 again (fails before 2.5h), Y 2 / 2, Z 6 / 2, W 2 / 0, D again then gone."""
    cards = {name: _card(session, name) for name in ("X", "Y", "Z", "W", "D")}
    for hour, rating in ((0, "again"), (1, "again"), (2, "again"), (3, "good")):
        _review(session, cards["X"], rating, hour)
    for hour in (4, 5):
        _review(session, cards["Y"], "again", hour)
    for hour, rating in ((0.5, "good"), (1.5, "good"), (3, "good"), (4, "good")):
        _review(session, cards["Z"], rating, hour)
    for hour in (6, 7):
        _review(session, cards["Z"], "again", hour)
    for hour in (4, 5):
        _review(session, cards["W"], "good", hour)
    _review(session, cards["D"], "again", 8)
    deck.delete_note(session, deck.get_card(session, cards["D"]).note_id)
    return cards


async def test_struggling_cards_ranks_existing_cards_by_fails(engine):
    with Session(engine) as session:
        cards = _seed_struggles(session)

    ranked = await _call(engine, "struggling_cards")
    assert [
        (r["card"]["front"], r["reviews"], r["again"], datetime.fromisoformat(r["last_again_at"]))
        for r in ranked
    ] == [
        ("X", 4, 3, T0 + timedelta(hours=2)),
        ("Y", 2, 2, T0 + timedelta(hours=5)),
        ("Z", 6, 2, T0 + timedelta(hours=7)),
    ]
    assert ranked[0]["card"]["id"] == str(cards["X"])

    since = (T0 + timedelta(hours=2.5)).isoformat()
    later = await _call(engine, "struggling_cards", since=since)
    assert [(r["card"]["front"], r["reviews"], r["again"]) for r in later] == [
        ("Y", 2, 2),
        ("Z", 4, 2),
    ]

    [top] = await _call(engine, "struggling_cards", limit=1)
    assert top["card"]["front"] == "X"
    assert await _fails(engine, "struggling_cards", limit=0)
    assert await _fails(engine, "struggling_cards", limit=101)


def test_struggling_cards_ties_break_on_ratio_then_latest_fail(session):
    a, b, c = (_card(session, name) for name in ("A", "B", "C"))
    _review(session, a, "again", 1)
    _review(session, a, "good", 2)
    _review(session, b, "again", 3)
    _review(session, b, "good", 4)
    _review(session, c, "again", 0)
    ranked = deck.struggling_cards(session)
    # C: 1/1; B and A: 1/2, B failed later
    assert [r.card.front for r in ranked] == ["C", "B", "A"]


# --- both tools ------------------------------------------------------------------------------


async def test_history_tools_are_read_only(engine):
    with Session(engine) as session:
        _seed_struggles(session)

    def snapshot() -> tuple:
        with Session(engine) as session:
            cards = sorted(c.model_dump_json() for c in session.exec(select(Card)))
            logs = session.exec(select(func.count()).select_from(ReviewLog)).one()
            events = session.exec(select(func.count()).select_from(ActivityEvent)).one()
            return cards, logs, events, deck.stats(session, now=T0 + timedelta(days=1))

    before = snapshot()
    await _call(engine, "review_history")
    await _call(engine, "struggling_cards")
    assert snapshot() == before


async def test_instructions_and_activity_log_point_to_history(engine):
    assert "`review_history`" in INSTRUCTIONS
    assert "`struggling_cards`" in INSTRUCTIONS
    async with Client(build_mcp(engine)) as client:
        tools = {t.name: t.description for t in (await client.list_tools()).tools}
    assert "`review_history`" in tools["activity_log"]
    assert "never pruned" in " ".join(tools["review_history"].split())
    assert "change nothing without the user's OK" in tools["struggling_cards"]
