"""Spec 022: risk-first order of the servable queue.

(Re)learning cards by due, then review cards lowest FSRS retrievability first, then new cards
oldest first (spec 021). Cards are put in a chosen FSRS state by setting their fields directly."""

import random
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import fsrs
import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.mcp_server import build_mcp
from la_carte_api.models import (
    Card,
    CardCreate,
    NoteCreate,
    Rating,
    ReportCreate,
    ReportReason,
)

NOW = datetime(2026, 11, 22, 12, tzinfo=UTC)
DAY = timedelta(days=1)


def _add(session, *fronts: str, now=NOW - 30 * DAY) -> list[Card]:
    added = deck.add_cards(session, [CardCreate(front=f, back=f) for f in fronts], now=now).added
    return [session.get(Card, c.id) for c in added]


def _set(
    session,
    card: Card,
    state: fsrs.State,
    *,
    stability: float,
    last_review: datetime,
    due: datetime,
) -> Card:
    card.fsrs_state = state.value
    card.step = None if state == fsrs.State.Review else 0
    card.stability = stability
    card.difficulty = 5.0
    card.last_review = last_review
    card.due = due
    session.add(card)
    session.commit()
    session.refresh(card)
    return card


def _review(session, card: Card, stability: float, days_ago: float, due_days_ago: float) -> Card:
    return _set(
        session,
        card,
        fsrs.State.Review,
        stability=stability,
        last_review=NOW - days_ago * DAY,
        due=NOW - due_days_ago * DAY,
    )


def _ids(session, now=NOW, limit=200) -> list:
    return [c.id for c in deck.due_cards(session, limit=limit, now=now)]


def _r(session, card_id, now=NOW) -> float:
    card = session.get(Card, card_id)
    return fsrs.Scheduler().get_card_retrievability(card.to_fsrs(), now)


def test_lowest_retrievability_first_not_oldest_due(session):  # AC 1
    a, b = _add(session, "a", "b")
    _review(session, a, stability=100, days_ago=110, due_days_ago=10)  # elapsed/S = 1.1
    _review(session, b, stability=2, days_ago=4, due_days_ago=1)  # elapsed/S = 2
    assert _r(session, b.id) < _r(session, a.id)
    assert _ids(session) == [b.id, a.id]


def test_served_retrievability_is_non_decreasing(session):  # AC 2
    rng = random.Random(22)
    cards = _add(session, *(f"w{i}" for i in range(30)))
    for card in cards:
        days_ago = rng.uniform(1, 200)
        _review(session, card, rng.uniform(0.5, 150), days_ago, due_days_ago=rng.uniform(0, 1))
    ids = _ids(session)
    assert len(ids) == 30
    risks = [_r(session, i) for i in ids]
    assert risks == sorted(risks)


def test_learning_and_relearning_come_before_every_review(session):  # AC 3
    risky, learning, relearning = _add(session, "risky", "learning", "relearning")
    # About the lowest R the FSRS curve gives (it flattens: ~0.2 here), far below the others'.
    _review(session, risky, stability=0.01, days_ago=365, due_days_ago=364)
    _set(
        session,
        learning,
        fsrs.State.Learning,
        stability=1,
        last_review=NOW - timedelta(minutes=10),
        due=NOW - timedelta(minutes=5),
    )
    _set(
        session,
        relearning,
        fsrs.State.Relearning,
        stability=0.5,
        last_review=NOW - timedelta(minutes=2),
        due=NOW - timedelta(minutes=1),
    )
    assert _r(session, risky.id) < min(_r(session, learning.id), _r(session, relearning.id))
    assert _ids(session) == [learning.id, relearning.id, risky.id]

    relearning.due = NOW - timedelta(minutes=8)  # the earlier due goes first
    session.add(relearning)
    session.commit()
    assert _ids(session) == [relearning.id, learning.id, risky.id]


def test_new_cards_come_after_started_cards_oldest_first(session):  # AC 4
    [older] = _add(session, "older", now=NOW - 3 * DAY)
    [newer] = _add(session, "newer", now=NOW - 2 * DAY)
    [review] = _add(session, "review")
    _review(session, review, stability=10, days_ago=10, due_days_ago=1 / 24)
    [learning] = _add(session, "learning")
    _set(
        session,
        learning,
        fsrs.State.Learning,
        stability=1,
        last_review=NOW - timedelta(minutes=10),
        due=NOW,
    )
    assert _ids(session) == [learning.id, review.id, older.id, newer.id]


PERSON = {
    "type": "person",
    "fields": {"photo": "https://example.org/ada.jpg", "name": "Ada", "description": "baker"},
    "directions": [
        {"prompt": ["photo"]},
        {"prompt": ["name"]},
        {"prompt": ["description"]},
    ],
}  # fmt: skip


def _siblings(session) -> list[Card]:
    [note] = deck.add_notes(session, [NoteCreate.model_validate(PERSON)], now=NOW - 30 * DAY).added
    return [session.get(Card, c.id) for c in note.cards]


def test_within_a_note_the_same_order_picks_the_winner(session):  # AC 5
    overdue, risky, _ = _siblings(session)
    _review(session, overdue, stability=100, days_ago=110, due_days_ago=10)
    _review(session, risky, stability=2, days_ago=4, due_days_ago=1)
    assert _ids(session) == [risky.id]  # lower retrievability, not the more overdue one
    deck.delete_note(session, risky.note_id)

    review, new, _ = _siblings(session)
    _review(session, review, stability=100, days_ago=110, due_days_ago=10)
    assert _ids(session) == [review.id]  # a due review sibling wins over a new sibling

    _set(
        session,
        new,
        fsrs.State.Relearning,
        stability=0.5,
        last_review=NOW - timedelta(hours=12),
        due=NOW - timedelta(minutes=1),
    )
    assert _ids(session) == [new.id]  # a (re)learning sibling wins over a review and a new one


def test_sibling_hold_and_stats_are_unchanged(session):  # AC 6
    reviewed, weakest, _ = _siblings(session)
    _review(session, reviewed, stability=50, days_ago=60, due_days_ago=1)
    _review(session, weakest, stability=0.2, days_ago=50, due_days_ago=49)
    [other] = _add(session, "other")
    _review(session, other, stability=20, days_ago=25, due_days_ago=1)
    deck.review_card(session, reviewed.id, Rating.good, now=NOW - timedelta(hours=1))
    session.refresh(reviewed)

    # The hold ends 6 h after that review (its new due is later); the new sibling has the same hold.
    hold_end = NOW + timedelta(hours=5)
    assert reviewed.due > hold_end
    assert _ids(session) == [other.id]  # the weakest card in the deck is held
    stats = deck.stats(session, now=NOW)
    assert (stats.due, stats.next_due) == (1, hold_end)

    assert _ids(session, now=hold_end) == [weakest.id, other.id]


def test_ties_fall_back_to_due_then_card_order_then_id(session):  # AC 7
    [first] = _add(session, "first", now=NOW - 30 * DAY)
    pair = _add(session, "p", "q", now=NOW - 20 * DAY)
    for card in [first, *pair]:
        _review(session, card, stability=10, days_ago=12, due_days_ago=2)
    [late] = _add(session, "late", now=NOW - 40 * DAY)
    _review(session, late, stability=10, days_ago=12, due_days_ago=1)  # same R, later due
    assert len({_r(session, c.id) for c in [first, *pair, late]}) == 1

    by_id = sorted(pair, key=lambda c: str(c.id))
    assert _ids(session) == [first.id, *(c.id for c in by_id), late.id]
    assert _ids(session) == _ids(session)


def test_limit_takes_the_head_of_the_queue(session):  # AC 8
    rng = random.Random(8)
    for card in _add(session, *(f"w{i}" for i in range(50))):
        _review(session, card, rng.uniform(1, 50), rng.uniform(2, 100), due_days_ago=1)
    assert _ids(session, limit=5) == _ids(session)[:5]


def test_report_held_cards_are_absent_and_do_not_change_the_order(session):  # AC 10
    rng = random.Random(10)
    cards = _add(session, *(f"w{i}" for i in range(10)))
    for card in cards:
        _review(session, card, rng.uniform(1, 50), rng.uniform(2, 100), due_days_ago=1)
    before = _ids(session)
    deck.report_card(session, before[0], ReportCreate(reason=ReportReason.wrong), now=NOW)
    deck.report_card(session, before[4], ReportCreate(reason=ReportReason.drop), now=NOW)
    assert _ids(session) == [i for i in before if i not in (before[0], before[4])]


def test_3000_due_reviews_are_ordered_in_under_a_second(session):  # AC 11
    rng = random.Random(11)
    for card in _add(session, *(f"w{i}" for i in range(3000))):
        days_ago = rng.uniform(1, 300)
        card.fsrs_state, card.step, card.difficulty = fsrs.State.Review.value, None, 5.0
        card.stability = rng.uniform(0.5, 200)
        card.last_review = NOW - days_ago * DAY
        card.due = NOW - rng.uniform(0, 1) * DAY
        session.add(card)
    session.commit()
    session.expunge_all()

    start = time.perf_counter()
    served = deck.due_cards(session, limit=200, now=NOW)
    elapsed = time.perf_counter() - start
    assert elapsed < 1
    assert len(served) == 200


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_rest_mcp_and_deck_agree(client, anyio_backend):  # AC 9 + AC 12 (docstring)
    engine = client.app.state.engine
    now = datetime.now(UTC)
    rng = random.Random(9)
    with Session(engine) as session:
        for card in _add(session, *(f"w{i}" for i in range(20)), now=now - 30 * DAY):
            card.fsrs_state, card.step, card.difficulty = fsrs.State.Review.value, None, 5.0
            card.stability = rng.uniform(1, 50)
            card.last_review = now - rng.uniform(2, 100) * DAY
            card.due = now - DAY
            session.add(card)
        session.commit()
        _add(session, "new", now=now - DAY)
        expected = [str(c.id) for c in deck.due_cards(session, limit=200)]

    rest = client.get("/cards/due", params={"limit": 200}).json()
    assert [c["id"] for c in rest] == expected
    assert set(rest[0]) == {
        "answer", "back", "created_at", "due", "fields", "front", "id", "last_review",
        "note_id", "prompt", "state", "type", "updated_at",
    }  # fmt: skip

    async with Client(build_mcp(engine)) as mcp:
        result = await mcp.call_tool("due_cards", {"limit": 200})
        assert [c["id"] for c in result.structured_content["result"]] == expected
        [tool] = [t for t in (await mcp.list_tools()).tools if t.name == "due_cards"]
        assert "most at risk" in tool.description


def test_architecture_states_the_order():  # AC 12
    text = (Path(__file__).parents[2] / "docs" / "architecture.md").read_text()
    assert "lowest FSRS retrievability first" in text
