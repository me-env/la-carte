"""The deck: every operation on cards. REST routes and MCP tools are thin wrappers around this."""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta, tzinfo
from itertools import islice
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import fsrs
from sqlmodel import Session, col, func, select

from la_carte_api.models import (
    Card,
    CardCreate,
    CardUpdate,
    DeckStats,
    Rating,
    ReviewLog,
    utcnow,
)

_scheduler = fsrs.Scheduler()
_DAY = timedelta(days=1)


class CardNotFound(LookupError):
    def __init__(self, card_id: UUID) -> None:
        super().__init__(f"No card with id {card_id}")


class UnknownTimeZone(ValueError):
    def __init__(self, name: str) -> None:
        super().__init__(f"Unknown time zone: {name}")


def time_zone(name: str) -> ZoneInfo:
    """The IANA time zone `name` (e.g. "Europe/Paris"), or `UnknownTimeZone`."""
    try:
        return ZoneInfo(name)
    # ValueError: malformed key ("../x"); OSError: e.g. a name too long for the file system.
    except (ZoneInfoNotFoundError, ValueError, OSError) as error:
        raise UnknownTimeZone(name) from error


def list_cards(session: Session, query: str | None = None, limit: int = 100) -> list[Card]:
    """Newest first. `query` is a trimmed, casefolded substring of front or back.

    Filtered in Python, not SQL: SQLite's LIKE only folds ASCII case ("été" must find "Été")."""
    statement = select(Card).order_by(col(Card.created_at).desc())
    needle = (query or "").strip().casefold()
    if not needle:
        return list(session.exec(statement.limit(limit)))
    matches = (
        card
        for card in session.exec(statement)
        if needle in card.front.casefold() or needle in card.back.casefold()
    )
    return list(islice(matches, limit))


def get_card(session: Session, card_id: UUID) -> Card:
    card = session.get(Card, card_id)
    if card is None:
        raise CardNotFound(card_id)
    return card


@dataclass
class AddedCards:
    added: list[Card]
    skipped: list[Card]  # existing cards whose front matched


def _front_key(front: str) -> str:
    return front.strip().casefold()


def add_cards(
    session: Session,
    cards: list[CardCreate],
    now: datetime | None = None,
    skip_duplicates: bool = False,
) -> AddedCards:
    """Adds cards, due immediately. With `skip_duplicates`, a card whose front matches an existing
    card's front (or an earlier card of the same call), ignoring case and surrounding whitespace,
    is not added and the matching card is reported in `skipped` instead."""
    now = now or utcnow()
    existing: dict[str, Card] = {}  # front key -> oldest card with that front
    if skip_duplicates:  # a single personal deck: matching in Python is fine
        for card in session.exec(select(Card).order_by(col(Card.created_at))):
            existing.setdefault(_front_key(card.front), card)

    result = AddedCards(added=[], skipped=[])
    for c in cards:
        key = _front_key(c.front)
        if skip_duplicates and key in existing:
            result.skipped.append(existing[key])
            continue
        card = Card(front=c.front, back=c.back, created_at=now, updated_at=now, due=now)
        existing[key] = card
        result.added.append(card)
    session.add_all(result.added)
    session.commit()
    # The commit expired these cards; reload so callers can read them after the session closes.
    for card in result.added + result.skipped:
        session.refresh(card)
    return result


def update_card(session: Session, card_id: UUID, changes: CardUpdate) -> Card:
    card = get_card(session, card_id)
    for field, value in changes.model_dump(exclude_none=True).items():
        setattr(card, field, value)
    card.updated_at = utcnow()
    session.commit()
    session.refresh(card)
    return card


def delete_card(session: Session, card_id: UUID) -> None:
    # Its ReviewLog rows stay (no foreign key): past study days still count for stats.
    session.delete(get_card(session, card_id))
    session.commit()


def due_cards(session: Session, limit: int = 20, now: datetime | None = None) -> list[Card]:
    statement = (
        select(Card).where(col(Card.due) <= (now or utcnow())).order_by(col(Card.due)).limit(limit)
    )
    return list(session.exec(statement))


def review_card(
    session: Session, card_id: UUID, rating: Rating, now: datetime | None = None
) -> Card:
    now = now or utcnow()
    card = get_card(session, card_id)
    scheduled, _ = _scheduler.review_card(card.to_fsrs(), rating.to_fsrs(), review_datetime=now)
    card.apply_fsrs(scheduled)
    session.add(ReviewLog(card_id=card.id, rating=rating, reviewed_at=now))
    session.commit()
    session.refresh(card)
    return card


def stats(session: Session, now: datetime | None = None, tz: tzinfo = UTC) -> DeckStats:
    """Deck counts at `now`. `reviewed_today` and `streak` use calendar days in `tz`."""
    now = now or utcnow()
    today = now.astimezone(tz).date()
    start_of_day, end_of_day = _local_midnight(today, tz), _local_midnight(today + _DAY, tz)

    def count(*where) -> int:
        return session.exec(select(func.count()).select_from(Card).where(*where)).one()

    reviewed_today = session.exec(
        select(func.count(func.distinct(ReviewLog.card_id))).where(
            col(ReviewLog.reviewed_at) >= start_of_day,
            col(ReviewLog.reviewed_at) < end_of_day,
        )
    ).one()
    review_times = session.exec(
        select(ReviewLog.reviewed_at)
        .where(col(ReviewLog.reviewed_at) < end_of_day)
        .order_by(col(ReviewLog.reviewed_at).desc())
    )
    return DeckStats(
        total=count(),
        due=count(col(Card.due) <= now),
        new=count(col(Card.last_review).is_(None)),
        reviewed_today=reviewed_today,
        next_due=session.exec(select(func.min(Card.due)).where(col(Card.due) > now)).one(),
        streak=_streak(
            (t.astimezone(tz).date() for t in review_times),
            last_day=today if reviewed_today else today - _DAY,  # alive until the end of today
        ),
    )


def _local_midnight(day: date, tz: tzinfo) -> datetime:
    """Start of `day` in `tz`, as UTC (a local day is 23 or 25 hours long across DST)."""
    return datetime.combine(day, time(), tzinfo=tz).astimezone(UTC)


def _streak(review_days: Iterable[date], last_day: date) -> int:
    """Consecutive review days ending on `last_day`. `review_days`: local dates, newest first."""
    streak, expected = 0, last_day
    for day in review_days:
        if day == expected:
            streak, expected = streak + 1, expected - _DAY
        elif day < expected:
            break  # a gap; a later day is another review on a day already counted
    return streak
