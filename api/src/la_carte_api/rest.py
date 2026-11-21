"""REST API consumed by the iOS app."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.db import sessions
from la_carte_api.models import CardCreate, CardRead, CardUpdate, DeckStats, ReviewCreate


def _session(request: Request):
    yield from sessions(request.app.state.engine)


SessionDep = Annotated[Session, Depends(_session)]
router = APIRouter()


@router.get("/cards", response_model=list[CardRead])
def list_cards(session: SessionDep, query: str | None = None, limit: int = Query(100, le=500)):
    return [CardRead.of(c) for c in deck.list_cards(session, query, limit)]


@router.post("/cards", response_model=CardRead, status_code=status.HTTP_201_CREATED)
def add_card(session: SessionDep, body: CardCreate):
    return CardRead.of(deck.add_cards(session, [body]).added[0])


@router.get("/cards/due", response_model=list[CardRead])
def due_cards(session: SessionDep, limit: int = Query(20, le=200)):
    return [CardRead.of(c) for c in deck.due_cards(session, limit)]


@router.get("/cards/{card_id}", response_model=CardRead)
def get_card(session: SessionDep, card_id: UUID):
    return CardRead.of(_or_404(deck.get_card, session, card_id))


@router.patch("/cards/{card_id}", response_model=CardRead)
def update_card(session: SessionDep, card_id: UUID, body: CardUpdate):
    return CardRead.of(_or_404(deck.update_card, session, card_id, body))


@router.delete("/cards/{card_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_card(session: SessionDep, card_id: UUID):
    _or_404(deck.delete_card, session, card_id)


@router.post("/cards/{card_id}/review", response_model=CardRead)
def review_card(session: SessionDep, card_id: UUID, body: ReviewCreate):
    return CardRead.of(
        _or_404(deck.review_card, session, card_id, body.rating, None, body.confidence)
    )


@router.get("/stats", response_model=DeckStats)
def stats(session: SessionDep, tz: str = "UTC"):
    """`tz`: IANA time zone defining "today" for `reviewed_today` and `streak`."""
    try:
        zone = deck.time_zone(tz)
    except deck.UnknownTimeZone as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error
    return deck.stats(session, tz=zone)


def _or_404(operation, *args):
    try:
        return operation(*args)
    except deck.CardNotFound as error:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(error)) from error
