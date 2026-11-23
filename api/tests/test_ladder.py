"""Spec 021 v3: the daily milestone ladder's counts on `/stats` (`at_risk_*`, `reviews_*`) and the
`ReviewLog` memory state they rest on. Paris days: 2026-11-22 starts at 2026-11-21 23:00 UTC."""

import sqlite3
from datetime import UTC, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

import fsrs
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.models import (
    Card,
    CardCreate,
    DeckStats,
    Rating,
    ReportCreate,
    ReportReason,
    ReviewLog,
)

PARIS = ZoneInfo("Europe/Paris")
MIDNIGHT = datetime(2026, 11, 22, tzinfo=PARIS).astimezone(UTC)
DAY = timedelta(days=1)


def at(hour: int, minute: int = 0) -> datetime:
    """`hour:minute` local time in Paris on 2026-11-22, as UTC."""
    return datetime(2026, 11, 22, hour, minute, tzinfo=PARIS).astimezone(UTC)


def _started(
    session: Session, count: int, stability: float, last_review: datetime, due=None, prefix="s"
) -> list[UUID]:
    """`count` cards in review state with this memory state and a review at `last_review`
    (due a day after it by default)."""
    added = deck.add_cards(
        session,
        [CardCreate(front=f"{prefix}{i}", back="x") for i in range(count)],
        now=last_review - DAY,
    ).added
    for read in added:
        card = session.get(Card, read.id)
        card.fsrs_state, card.step = fsrs.State.Review.value, None
        card.stability, card.difficulty = stability, 5.0
        card.last_review, card.due = last_review, due or last_review + DAY
        session.add(card)
        session.add(ReviewLog(card_id=card.id, rating=Rating.good, reviewed_at=last_review))
    session.commit()
    return [read.id for read in added]


def _at_risk(session: Session, count: int, prefix="r") -> list[UUID]:
    """Recall at midnight about 0.67 (< 0.8)."""
    return _started(session, count, 1.0, MIDNIGHT - 10 * DAY, prefix=prefix)


def _new(session: Session, count: int) -> list[UUID]:
    cards = [CardCreate(front=f"n{i}", back="x") for i in range(count)]
    return [c.id for c in deck.add_cards(session, cards, now=MIDNIGHT - DAY).added]


def _stats(session: Session, now: datetime) -> DeckStats:
    """`/stats` in Paris, with the spec's invariants checked on every call (AC 10)."""
    stats = deck.stats(session, now=now, tz=PARIS)
    assert 0 <= stats.at_risk_done <= stats.at_risk_total
    assert stats.at_risk_total == 0 or stats.at_risk_total >= deck.AT_RISK_MIN
    assert 0 <= stats.reviews_done <= stats.reviews_total
    assert stats.reviews_done == stats.reviewed_today - stats.new_today
    return stats


def _at_risk_counts(session: Session, now: datetime) -> tuple[int, int]:
    stats = _stats(session, now)
    return stats.at_risk_total, stats.at_risk_done


def _reviews_counts(session: Session, now: datetime) -> tuple[int, int]:
    stats = _stats(session, now)
    return stats.reviews_total, stats.reviews_done


def _log(session: Session, card_id: UUID) -> ReviewLog:
    return session.exec(
        select(ReviewLog).where(ReviewLog.card_id == card_id).order_by(ReviewLog.id.desc())
    ).first()


# --- AC 4: the review log keeps the memory state before the review ------------------------------


def test_review_log_stores_the_state_before_the_review(session):
    [new] = _new(session, 1)
    deck.review_card(session, new, Rating.good, now=at(9))
    assert (_log(session, new).stability_before, _log(session, new).last_review_before) == (
        None,
        None,
    )

    before = session.get(Card, new)
    stability, last_review = before.stability, before.last_review
    deck.review_card(session, new, Rating.good, now=at(10))
    log = _log(session, new)
    assert (log.stability_before, log.last_review_before) == (stability, last_review)
    assert session.get(Card, new).last_review == at(10)


# --- AC 5: migration ---------------------------------------------------------------------------


def _reviewlog_columns(path) -> dict[str, list]:
    db = sqlite3.connect(path)
    columns = [r[1] for r in db.execute("PRAGMA table_info(reviewlog)")]
    rows = db.execute("SELECT * FROM reviewlog ORDER BY id").fetchall()
    db.close()
    return {name: [row[i] for row in rows] for i, name in enumerate(columns)}


def test_migration_adds_the_memory_columns_once(tmp_path):
    path = tmp_path / "deck.db"
    url = f"sqlite:///{path}"
    engine = make_engine(url)
    with Session(engine) as session:
        [card] = _new(session, 1)
        deck.review_card(session, card, Rating.good, now=at(9))
        deck.review_card(session, card, Rating.good, now=at(10))
    engine.dispose()
    db = sqlite3.connect(path)
    for column in ("stability_before", "last_review_before"):
        db.execute(f"ALTER TABLE reviewlog DROP COLUMN {column}")  # as before spec 021 v3
    db.commit()
    db.close()

    make_engine(url).dispose()
    columns = _reviewlog_columns(path)
    assert columns["stability_before"] == columns["last_review_before"] == [None, None]

    make_engine(url).dispose()  # a second start changes nothing
    assert _reviewlog_columns(path) == columns
    assert list(tmp_path.glob("*.bak")) == []  # columns are added in place, like `confidence`


# --- AC 6-8: at risk ---------------------------------------------------------------------------


def test_at_risk_is_a_snapshot_of_the_start_of_the_day(session):  # AC 6
    risky = _at_risk(session, 12)
    safe = _started(session, 2, 100.0, MIDNIGHT - 2 * DAY, prefix="safe")
    # Recall 0.81 at midnight (3 days since 15:00), 0.78 from 15:00 (4 days).
    [crossing] = _started(session, 1, 1.0, MIDNIGHT - 3 * DAY - timedelta(hours=9), prefix="x")
    assert _at_risk_counts(session, at(8)) == (12, 0)

    for i, card in enumerate(risky[:5]):
        deck.review_card(session, card, Rating.again if i == 0 else Rating.good, now=at(10))
    assert _at_risk_counts(session, at(10, 5)) == (12, 5)

    deck.review_card(session, safe[0], Rating.good, now=at(11))
    assert _at_risk_counts(session, at(11, 5)) == (12, 5)
    card = session.get(Card, crossing)
    assert deck._was_at_risk(card.stability, card.last_review, at(15))  # at risk from 15:00...
    assert _at_risk_counts(session, at(16)) == (12, 5)  # ...but not added


def test_at_risk_needs_at_least_ten_cards(session):  # AC 7
    nine = _at_risk(session, 9)
    assert _at_risk_counts(session, at(8)) == (0, 0)
    for card in nine:
        deck.review_card(session, card, Rating.good, now=at(9))
    assert _at_risk_counts(session, at(10)) == (0, 0)

    _at_risk(session, 1, prefix="tenth")
    assert _at_risk_counts(session, at(10)) == (10, 9)


def test_ten_at_risk_cards_make_the_step(session):  # AC 7
    _at_risk(session, 10)
    assert _at_risk_counts(session, at(8)) == (10, 0)


def test_held_and_deleted_cards_leave_at_risk_unless_reviewed_today(session):  # AC 8
    held, deleted, reviewed, *_ = _at_risk(session, 12)
    deck.report_card(session, held, ReportCreate(reason=ReportReason.wrong), now=at(8))
    deck.delete_card(session, deleted)
    assert _at_risk_counts(session, at(9)) == (10, 0)

    deck.review_card(session, reviewed, Rating.good, now=at(9))
    deck.delete_card(session, reviewed)
    assert _at_risk_counts(session, at(10)) == (10, 1)


def test_reviews_before_the_columns_existed_are_never_at_risk(session):
    cards = _at_risk(session, 10)
    for card in cards:
        deck.review_card(session, card, Rating.good, now=at(9))
    for log in session.exec(select(ReviewLog)):
        log.stability_before = log.last_review_before = None  # a pre-deploy row
        session.add(log)
    session.commit()
    assert _at_risk_counts(session, at(10)) == (0, 0)


# --- AC 9: reviews -----------------------------------------------------------------------------


def test_reviews_count_cards_started_before_today(session):
    a, b, _ = _started(session, 3, 10.0, MIDNIGHT - 5 * DAY, prefix="started")
    _started(session, 1, 10.0, MIDNIGHT - 8 * DAY, due=at(15), prefix="late")
    new, _ = _new(session, 2)
    assert _reviews_counts(session, at(8)) == (3, 0)

    deck.review_card(session, a, Rating.good, now=at(9))
    deck.review_card(session, new, Rating.good, now=at(9))
    assert _reviews_counts(session, at(9, 1)) == (3, 1)

    queue = [card.id for card in deck.due_cards(session, limit=50, now=at(9, 30))]
    assert new in queue  # its learning step: served, doesn't reopen the step
    assert _reviews_counts(session, at(9, 30)) == (3, 1)

    deck.review_card(session, a, Rating.again, now=at(9, 40))
    assert a in [card.id for card in deck.due_cards(session, limit=50, now=at(10, 0))]
    assert _reviews_counts(session, at(10)) == (3, 1)

    assert _reviews_counts(session, at(14, 59)) == (3, 1)
    assert _reviews_counts(session, at(15)) == (4, 1)  # `late` fell due
    deck.review_card(session, b, Rating.good, now=at(15, 5))
    assert _reviews_counts(session, at(15, 10)) == (4, 2)


# --- AC 10: on a mixed day ---------------------------------------------------------------------


def test_reviews_done_is_reviewed_today_minus_new_today_on_a_mixed_day(session):
    risky = _at_risk(session, 11)
    started = _started(session, 3, 10.0, MIDNIGHT - 5 * DAY, prefix="started")
    new = _new(session, 4)
    for i, card in enumerate([*risky[:6], *started[:2], *new[:3]]):
        deck.review_card(session, card, [Rating.again, Rating.good][i % 2], now=at(9, i))
    deck.delete_card(session, new[0])
    deck.review_card(session, risky[1], Rating.good, now=at(11))

    stats = _stats(session, at(12))
    assert (stats.at_risk_total, stats.at_risk_done) == (11, 6)
    assert (stats.reviewed_today, stats.new_today, stats.reviews_done) == (11, 3, 8)
