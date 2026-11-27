"""Spec 028: `Note.next`, the card Study serves first for a note and when, read from the queue."""

from datetime import UTC, datetime, timedelta
from uuid import UUID

import fsrs
import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.mcp_server import build_mcp
from la_carte_api.models import (
    Card,
    NoteCreate,
    Rating,
    ReportCreate,
    ReportOutcome,
    ReportReason,
)

NOW = datetime(2026, 11, 25, 12, tzinfo=UTC)
DAY = timedelta(days=1)
HOUR = timedelta(hours=1)

ONE_WAY = [{"prompt": ["front"]}]
BOTH_WAYS = [{"prompt": ["front"]}, {"prompt": ["back"]}]


def _note(session, front: str, directions=ONE_WAY, now=NOW - 30 * DAY) -> list[Card]:
    body = {"type": "basic", "fields": {"front": front, "back": front + " back"}}
    body["directions"] = directions
    [note] = deck.add_notes(session, [NoteCreate.model_validate(body)], now=now).added
    return [session.get(Card, c.id) for c in note.cards]


def _set(
    session, card: Card, state: fsrs.State, *, stability: float, last: datetime, due: datetime
):
    card.fsrs_state = state.value
    card.step = None if state == fsrs.State.Review else 0
    card.stability = stability
    card.difficulty = 5.0
    card.last_review = last
    card.due = due
    session.add(card)
    session.commit()
    session.refresh(card)
    return card


def _review(session, card: Card, *, days_ago: float, due_in: float, stability: float = 10):
    return _set(
        session,
        card,
        fsrs.State.Review,
        stability=stability,
        last=NOW - days_ago * DAY,
        due=NOW + due_in * DAY,
    )


def _hold(session, card: Card):
    return deck.report_card(session, card.id, ReportCreate(reason=ReportReason.wrong), now=NOW)[0]


def _nexts(session, now=NOW) -> dict:
    return {note.id: note.next for note in deck.list_notes(session, limit=500, now=now)}


def _mixed_deck(session) -> None:
    """New, review (due and not), learning, relearning, buried siblings, reported cards."""
    _note(session, "new")
    _note(session, "new both", BOTH_WAYS)
    _review(session, _note(session, "due review")[0], days_ago=20, due_in=-2)
    _review(session, _note(session, "later review")[0], days_ago=2, due_in=5)
    [learning] = _note(session, "learning")
    _set(session, learning, fsrs.State.Learning, stability=1, last=NOW - HOUR, due=NOW - 0.5 * HOUR)
    [relearning] = _note(session, "relearning later")
    _set(session, relearning, fsrs.State.Relearning, stability=1, last=NOW, due=NOW + HOUR)
    # A sibling reviewed 1 h ago buries the other one (due, new) until 5 h from now.
    reviewed, buried = _note(session, "buried", BOTH_WAYS)
    _review(session, reviewed, days_ago=40, due_in=-1, stability=50)
    deck.review_card(session, reviewed.id, Rating.good, now=NOW - HOUR)
    # A learning card is never buried: its sibling was just reviewed, it is still served.
    first, failed = _note(session, "learning sibling", BOTH_WAYS)
    _review(session, first, days_ago=40, due_in=-1, stability=50)
    deck.review_card(session, first.id, Rating.good, now=NOW - HOUR)
    _set(session, failed, fsrs.State.Relearning, stability=1, last=NOW - DAY, due=NOW - HOUR)
    _hold(session, _note(session, "reported")[0])
    held, other = _note(session, "half reported", BOTH_WAYS)
    _review(session, other, days_ago=10, due_in=-1)
    _hold(session, held)


def test_every_note_response_has_next(client):  # AC 1
    created = client.post("/notes", json={"type": "basic", "fields": {"front": "a", "back": "b"}})
    assert created.status_code == 201
    card_id = created.json()["cards"][0]["id"]
    assert created.json()["next"]["card_id"] == card_id
    note_id = created.json()["id"]
    for response in (
        client.get("/notes"),
        client.get(f"/notes/{note_id}"),
        client.patch(f"/notes/{note_id}", json={"fields": {"back": "c"}}),
    ):
        note = response.json()[0] if isinstance(response.json(), list) else response.json()
        assert set(note["next"]) == {"card_id", "ready_at"}
        assert note["next"]["card_id"] == card_id
        assert datetime.fromisoformat(note["next"]["ready_at"]) <= datetime.now(UTC)


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_mcp_notes_have_next(engine, anyio_backend):  # AC 1
    async with Client(build_mcp(engine)) as client:
        added = await client.call_tool(
            "add_notes",
            {
                "notes": [
                    {"type": "basic", "fields": {"front": "a", "back": "b"}, "directions": ONE_WAY}
                ]
            },
        )
        [note] = added.structured_content["added"]
        card_id = note["cards"][0]["id"]
        assert note["next"]["card_id"] == card_id
        [found] = (await client.call_tool("find_notes", {})).structured_content["result"]
        updated = await client.call_tool(
            "update_note", {"note_id": note["id"], "fields": {"back": "c"}}
        )
        for read in (found, updated.structured_content):
            assert read["next"]["card_id"] == card_id
        with Session(engine) as session:
            _hold(session, session.get(Card, UUID(card_id)))
        [found] = (await client.call_tool("find_notes", {})).structured_content["result"]
        assert found["next"] is None


def test_notes_ready_now_are_exactly_the_study_queue(session):  # AC 2, AC 3
    _mixed_deck(session)
    queue = deck.due_cards(session, limit=10_000, now=NOW)
    ready = {
        note_id: n.card_id for note_id, n in _nexts(session).items() if n and n.ready_at <= NOW
    }
    assert ready == {card.note_id: card.id for card in queue}
    assert len(queue) == len(ready) == 6  # sanity: the deck mixes ready and not-ready notes
    assert deck.stats(session, now=NOW).due == len(ready)


def test_a_new_note_is_ready_with_its_first_card(session):  # AC 4
    cards = _note(session, "fresh", BOTH_WAYS, now=NOW - HOUR)
    [read] = deck.list_notes(session, now=NOW)
    assert read.next.card_id == deck.due_cards(session, now=NOW)[0].id == cards[0].id
    assert read.next.ready_at == cards[0].due <= NOW


def test_reviewing_a_new_card_keeps_the_note_off_the_queue_until_its_step(session):  # AC 5
    reviewed, _ = _note(session, "pair", BOTH_WAYS)
    t = NOW
    deck.review_card(session, reviewed.id, Rating.good, now=t)
    session.refresh(reviewed)
    for now in (t, t + timedelta(minutes=1)):
        [read] = deck.list_notes(session, now=now)
        assert read.next.ready_at == min(t + deck.SIBLING_BURY, reviewed.due) > now
        assert read.next.card_id == reviewed.id  # (re)learning, ready no later than its sibling


def test_reviewing_a_review_card_buries_its_sibling_six_hours(session):  # AC 5
    reviewed, sibling = _note(session, "pair", BOTH_WAYS)
    _review(session, reviewed, days_ago=40, due_in=-1, stability=50)
    t = NOW
    deck.review_card(session, reviewed.id, Rating.good, now=t)
    session.refresh(reviewed)
    assert reviewed.due > t + deck.SIBLING_BURY
    for now in (t, t + 5 * HOUR):
        [read] = deck.list_notes(session, now=now)
        assert (read.next.card_id, read.next.ready_at) == (sibling.id, t + deck.SIBLING_BURY)
    [read] = deck.list_notes(session, now=t + deck.SIBLING_BURY)
    assert read.next.ready_at <= t + deck.SIBLING_BURY  # the bury has ended: in the queue


def test_reported_cards_have_no_next(session):  # AC 6
    [alone] = _note(session, "alone")
    held, other = _note(session, "pair", BOTH_WAYS)
    report = _hold(session, alone)
    _hold(session, held)
    nexts = _nexts(session)
    assert nexts[alone.note_id] is None
    assert nexts[held.note_id].card_id == other.id
    deck.update_report(session, report.id, ReportOutcome.kept, "fine", now=NOW)
    assert _nexts(session)[alone.note_id].card_id == alone.id


def test_no_card_ready_gives_the_earliest(session):  # AC 7
    late, soon = _note(session, "pair", BOTH_WAYS)
    _review(session, late, days_ago=2, due_in=9)
    _review(session, soon, days_ago=2, due_in=3)
    assert _nexts(session)[late.note_id].card_id == soon.id
    assert _nexts(session)[late.note_id].ready_at == soon.due

    first, second = _note(session, "tie", BOTH_WAYS)
    for card in (first, second):
        _review(session, card, days_ago=2, due_in=4)
    assert _nexts(session)[first.note_id].card_id == first.id  # tie: queue order (card order)
