"""Spec 023: review dues spread over the library's fuzz window, toward days with fewer cards due.

The reference interval is what FSRS gives without fuzz on the same card state. Cards are put in a
chosen FSRS state by setting their fields directly."""

import time
from datetime import UTC, datetime, timedelta
from functools import cache
from random import Random

import fsrs
import pytest
from mcp import Client
from sqlalchemy import event
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.mcp_server import build_mcp
from la_carte_api.models import Card, CardCreate, Rating

NOW = datetime(2026, 11, 22, 12, tzinfo=UTC)
DAY = timedelta(days=1)
_reference_scheduler = fsrs.Scheduler(enable_fuzzing=False)


def _reference(card: Card, rating: Rating = Rating.good, now: datetime = NOW) -> fsrs.Card:
    scheduled, _ = _reference_scheduler.review_card(card.to_fsrs(), rating.to_fsrs(), now)
    return scheduled


def _add(session, count: int, prefix: str = "c") -> list[Card]:
    fronts = [CardCreate(front=f"{prefix}{i}", back="x") for i in range(count)]
    added = deck.add_cards(session, fronts, now=NOW - 400 * DAY).added
    return [session.get(Card, c.id) for c in added]


def _set_review(card: Card, stability: float, last_review: datetime = NOW - DAY) -> None:
    card.fsrs_state, card.step = fsrs.State.Review.value, None
    card.stability, card.difficulty = stability, 5.0
    card.last_review, card.due = last_review, NOW


@cache
def _stability_for(interval: int) -> float:
    """The stability whose Good reference interval is `interval` days (binary search)."""
    card, lo, hi = Card(prompt=[], answer=[]), 0.01, 5000.0
    for _ in range(60):
        _set_review(card, (lo + hi) / 2)
        if (_reference(card).due - NOW).days < interval:
            lo = card.stability
        else:
            hi = card.stability
    return hi


def _review_card_with_interval(session, card: Card, interval: int) -> None:
    """Puts `card` in review with a Good reference interval of `interval` days."""
    _set_review(card, _stability_for(interval))
    session.commit()
    assert (_reference(card).due - NOW).days == interval


def _load_days(session, cards: list[Card], days: dict[int, int]) -> None:
    """Makes `days[k]` of `cards` due at `NOW + k days` (the end of day `k`)."""
    it = iter(cards)
    for day, count in days.items():
        for _ in range(count):
            next(it).due = NOW + day * DAY
    session.commit()


def _day(session, card: Card, interval: int, seed: int) -> int:
    _review_card_with_interval(session, card, interval)
    reviewed = deck.review_card(session, card.id, Rating.good, now=NOW, rng=Random(seed))
    shift = reviewed.due - NOW
    assert shift % DAY == timedelta(0)
    return shift // DAY


# AC 1
@pytest.mark.parametrize("seed", range(5))
def test_learning_steps_are_never_moved(session, seed):
    [card] = _add(session, 1)
    reference = _reference(card)
    reviewed = deck.review_card(session, card.id, Rating.good, now=NOW, rng=Random(seed))
    assert reviewed.due == reference.due == NOW + timedelta(minutes=10)

    _review_card_with_interval(session, card, 20)
    reference = _reference(card, Rating.again)
    assert reference.state == fsrs.State.Relearning
    reviewed = deck.review_card(session, card.id, Rating.again, now=NOW, rng=Random(seed))
    assert reviewed.due == reference.due == NOW + timedelta(minutes=10)


# AC 2
@pytest.mark.parametrize("interval", [1, 2])
def test_intervals_under_3_days_are_never_moved(session, interval):
    [card] = _add(session, 1)
    for seed in range(20):
        assert _day(session, card, interval, seed) == interval


# AC 3
def test_balance_window_is_the_library_fuzz_window():
    assert [deck._balance_window(i) for i in (3, 20, 100, 365)] == [
        (2, 4),
        (17, 23),
        (93, 107),
        (345, 385),
    ]
    maximum = deck._scheduler.maximum_interval
    assert deck._balance_window(maximum) == (deck._balance_window(maximum)[0], maximum)
    assert all(deck._balance_window(i)[1] <= maximum for i in range(3, maximum + 1, 97))


# AC 4
@pytest.mark.parametrize("interval", [3, 8, 20, 100])
def test_due_lands_on_a_whole_day_in_the_window(session, interval):
    [card] = _add(session, 1)
    lo, hi = deck._balance_window(interval)
    for seed in range(50):
        assert lo <= _day(session, card, interval, seed) <= hi


# AC 5
def test_day_weight():
    assert deck._day_weight(0, 10) == 1.0
    assert deck._day_weight(4, 10) == (1 / 4) ** 2.15 * (1 / 10) ** 3


@pytest.fixture
def loaded(session):
    """A card with a Good reference interval of 20, and 20 other cards due on each day 17-23."""
    card, *others = _add(session, 1 + 7 * 20)
    _load_days(session, others, dict.fromkeys(range(17, 24), 20))
    return card, others


# AC 6
def test_prefers_the_light_day(session, loaded):
    card, others = loaded
    _load_days(session, others[80:100], {400: 20})  # day 21's cards, out of the window
    picks = [_day(session, card, 20, seed) for seed in range(100)]
    assert picks.count(21) >= 90


# AC 7
def test_equal_load_stays_random(session, loaded):
    card, _ = loaded
    assert len({_day(session, card, 20, seed) for seed in range(50)}) >= 3


# AC 8
def test_same_seed_same_due(session, loaded):
    card, _ = loaded
    assert _day(session, card, 20, 7) == _day(session, card, 20, 7)


# AC 9
def test_day_buckets(session):
    card, at_5, at_4, after_5 = _add(session, 4)
    card.due, at_5.due, at_4.due = NOW + 5 * DAY, NOW + 5 * DAY, NOW + 4 * DAY
    after_5.due = NOW + 5 * DAY + timedelta(microseconds=1)
    session.commit()
    assert deck._day_loads(session, card.id, NOW, 3, 7) == {3: 0, 4: 1, 5: 1, 6: 1, 7: 0}


# AC 9, through the pick: the one loaded day loses whichever card is loaded on it.
@pytest.mark.parametrize("delta", [timedelta(0), -DAY + timedelta(microseconds=1)])
def test_a_loaded_day_is_avoided(session, delta):
    card, *others = _add(session, 1 + 30)
    for other in others:
        other.due = NOW + 3 * DAY + delta  # all on day 3
    session.commit()
    picks = {_day(session, card, 3, seed) for seed in range(30)}
    assert picks == {2, 4}


def test_the_reviewed_card_does_not_count_itself(session):
    [card] = _add(session, 1)
    _review_card_with_interval(session, card, 20)
    assert deck._day_loads(session, card.id, NOW, 17, 23) == dict.fromkeys(range(17, 24), 0)
    card.due = NOW + 20 * DAY
    session.commit()
    assert deck._day_loads(session, card.id, NOW, 17, 23) == dict.fromkeys(range(17, 24), 0)


# AC 10
def test_no_drift(session):
    [card] = _add(session, 1)
    last_review = NOW - 20 * DAY
    _set_review(card, stability=20.0, last_review=last_review)
    card.due = last_review + 23 * DAY  # the last interval (20 d) was shifted by +3 days
    reference = (_reference(card).due - NOW).days
    lo, hi = deck._balance_window(reference)
    for seed in range(20):
        card.fsrs_state, card.stability, card.difficulty = fsrs.State.Review.value, 20.0, 5.0
        card.last_review, card.due = last_review, last_review + 23 * DAY
        session.commit()
        due = deck.review_card(session, card.id, Rating.good, now=NOW, rng=Random(seed)).due
        assert lo <= (due - NOW) // DAY <= hi
    assert sorted(Card.__table__.columns.keys()) == [
        "answer",
        "created_at",
        "difficulty",
        "due",
        "fsrs_state",
        "id",
        "last_review",
        "note_id",
        "prompt",
        "stability",
        "step",
        "updated_at",
    ]


# AC 11
def test_one_query_per_balanced_review(engine, session):
    short, long = _add(session, 2)
    statements: list[str] = []

    def record(conn, cursor, statement, *args):
        statements.append(statement)

    def selects(card: Card, interval: int) -> list[str]:
        _review_card_with_interval(session, card, interval)
        statements.clear()
        event.listen(engine, "before_cursor_execute", record)
        try:
            deck.review_card(session, card.id, Rating.good, now=NOW, rng=Random(0))
        finally:
            event.remove(engine, "before_cursor_execute", record)
        return [s for s in statements if s.lstrip().upper().startswith("SELECT")]

    unbalanced, balanced = selects(short, 2), selects(long, 20)
    assert len(balanced) == len(unbalanced) + 1
    [extra] = [s for s in balanced if s not in unbalanced]
    assert "FROM card" in extra and "card.due >" in extra and "card.due <=" in extra


# AC 12
def test_balancing_is_fast_on_a_big_deck(session):
    card, *others = _add(session, 5001)
    for i, other in enumerate(others):
        other.fsrs_state, other.step = fsrs.State.Review.value, None
        other.due = NOW + DAY + (i % 400) * DAY
    session.commit()
    _review_card_with_interval(session, card, 365)
    start = time.perf_counter()
    reviewed = deck.review_card(session, card.id, Rating.good, now=NOW, rng=Random(0))
    assert time.perf_counter() - start < 0.2
    lo, hi = deck._balance_window(365)
    assert lo <= (reviewed.due - NOW) // DAY <= hi


# AC 13: Easy on a new card gives a review interval of 8 days in FSRS 6 (reference, no fuzz).
def _easy_window() -> tuple[int, int]:
    first, _ = _reference_scheduler.review_card(fsrs.Card(card_id=0), fsrs.Rating.Easy, NOW)
    assert first.state == fsrs.State.Review
    return deck._balance_window((first.due - NOW).days)


def _shift_in_window(reviewed: dict) -> None:
    lo, hi = _easy_window()
    shift = datetime.fromisoformat(reviewed["due"]) - datetime.fromisoformat(
        reviewed["last_review"]
    )
    assert shift % DAY == timedelta(0) and lo <= shift // DAY <= hi


def test_rest_review_is_balanced(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    reviewed = client.post(f"/cards/{card['id']}/review", json={"rating": "easy"}).json()
    assert reviewed.keys() == card.keys()
    _shift_in_window(reviewed)


@pytest.mark.anyio
@pytest.mark.parametrize("anyio_backend", ["asyncio"])
async def test_mcp_review_is_balanced(engine, anyio_backend):
    with Session(engine) as session:
        [card] = deck.add_cards(session, [CardCreate(front="chat", back="cat")]).added
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool("review_card", {"card_id": str(card.id), "rating": "easy"})
    reviewed = result.structured_content
    assert reviewed.keys() == card.model_dump().keys()
    _shift_in_window(reviewed)
