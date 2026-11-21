"""The deck: every operation on cards. REST routes and MCP tools are thin wrappers around this."""

from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

import fsrs
from sqlmodel import Session, col, func, or_, select

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


class CardNotFound(LookupError):
    def __init__(self, card_id: UUID) -> None:
        super().__init__(f"No card with id {card_id}")


def list_cards(session: Session, query: str | None = None, limit: int = 100) -> list[Card]:
    statement = select(Card).order_by(col(Card.created_at).desc()).limit(limit)
    if query:
        pattern = f"%{query}%"
        statement = statement.where(
            or_(col(Card.front).ilike(pattern), col(Card.back).ilike(pattern))
        )
    return list(session.exec(statement))


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


def stats(session: Session, now: datetime | None = None) -> DeckStats:
    now = now or utcnow()
    start_of_day = now.replace(hour=0, minute=0, second=0, microsecond=0)

    def count(*where) -> int:
        return session.exec(select(func.count()).select_from(Card).where(*where)).one()

    reviewed_today = session.exec(
        select(func.count(func.distinct(ReviewLog.card_id))).where(
            col(ReviewLog.reviewed_at) >= start_of_day,
            col(ReviewLog.reviewed_at) < start_of_day + timedelta(days=1),
        )
    ).one()
    return DeckStats(
        total=count(),
        due=count(col(Card.due) <= now),
        new=count(col(Card.last_review).is_(None)),
        reviewed_today=reviewed_today,
        next_due=session.exec(select(func.min(Card.due)).where(col(Card.due) > now)).one(),
    )
