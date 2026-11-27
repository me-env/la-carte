"""REST API consumed by the iOS app."""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.db import sessions
from la_carte_api.models import (
    ActivityBatch,
    ActivityEventRead,
    ActivityIngest,
    CardCreate,
    CardRead,
    CardUpdate,
    DeckStats,
    NoteCreate,
    NoteRead,
    NoteType,
    NoteUpdate,
    ReportCreate,
    ReportRead,
    ReviewCreate,
)


def _session(request: Request):
    yield from sessions(request.app.state.engine)


SessionDep = Annotated[Session, Depends(_session)]
router = APIRouter()


# --- Notes (spec 014a) -------------------------------------------------------------------------


@router.get("/notes", response_model=list[NoteRead])
def list_notes(
    session: SessionDep,
    query: str | None = None,
    type: NoteType | None = None,
    limit: int = Query(100, le=500),
):
    return deck.list_notes(session, query, type, limit)


@router.post("/notes", response_model=NoteRead, status_code=status.HTTP_201_CREATED)
def add_note(session: SessionDep, body: NoteCreate):
    return _call(deck.add_notes, session, [body]).added[0]


@router.get("/notes/{note_id}", response_model=NoteRead)
def get_note(session: SessionDep, note_id: UUID):
    return _call(deck.get_note, session, note_id)


@router.patch("/notes/{note_id}", response_model=NoteRead)
def update_note(session: SessionDep, note_id: UUID, body: NoteUpdate):
    return _call(deck.update_note, session, note_id, body)


@router.delete("/notes/{note_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_note(session: SessionDep, note_id: UUID):
    _call(deck.delete_note, session, note_id)


# --- Cards -------------------------------------------------------------------------------------


@router.get("/cards", response_model=list[CardRead])
def list_cards(session: SessionDep, query: str | None = None, limit: int = Query(100, le=500)):
    return deck.list_cards(session, query, limit)


@router.post("/cards", response_model=CardRead, status_code=status.HTTP_201_CREATED)
def add_card(session: SessionDep, body: CardCreate):
    return _call(deck.add_cards, session, [body]).added[0]


@router.get("/cards/due", response_model=list[CardRead])
def due_cards(session: SessionDep, limit: int = Query(20, le=200)):
    return deck.due_cards(session, limit)


@router.get("/cards/{card_id}", response_model=CardRead)
def get_card(session: SessionDep, card_id: UUID):
    return _call(deck.get_card, session, card_id)


@router.patch("/cards/{card_id}", response_model=CardRead)
def update_card(session: SessionDep, card_id: UUID, body: CardUpdate):
    return _call(deck.update_card, session, card_id, body)


@router.delete("/cards/{card_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_card(session: SessionDep, card_id: UUID):
    _call(deck.delete_card, session, card_id)


@router.post("/cards/{card_id}/review", response_model=CardRead)
def review_card(session: SessionDep, card_id: UUID, body: ReviewCreate):
    return _call(deck.review_card, session, card_id, body.rating, None, body.confidence)


@router.post(
    "/cards/{card_id}/report", response_model=ReportRead, status_code=status.HTTP_201_CREATED
)
def report_card(session: SessionDep, card_id: UUID, body: ReportCreate, response: Response):
    """Holds the card out of study until an agent closes the report (spec 015).
    An already active `broken_photo` report is returned with 200 instead of a new one."""
    report, created = _call(deck.report_card, session, card_id, body)
    if not created:
        response.status_code = status.HTTP_200_OK
    return report


@router.get("/stats", response_model=DeckStats)
def stats(session: SessionDep, tz: str = "UTC"):
    """`tz`: IANA time zone defining the local days of `reviewed_today`, `new_today`, `streak`
    and `history`."""
    try:
        zone = deck.time_zone(tz)
    except deck.UnknownTimeZone as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error
    return deck.stats(session, tz=zone)


# --- Activity (spec 029) ----------------------------------------------------------------------


@router.post("/activity", response_model=ActivityIngest)
def post_activity(session: SessionDep, body: ActivityBatch):
    """The app's activity events; each is validated on its own (invalid ones are `rejected`)."""
    try:
        return deck.ingest_activity(session, body.events)
    except deck.TooManyEvents as error:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, str(error)) from error


@router.get("/activity", response_model=list[ActivityEventRead])
def list_activity(
    session: SessionDep,
    since: datetime | None = None,
    until: datetime | None = None,
    card_id: UUID | None = None,
    kind: str | None = None,
    session_id: Annotated[UUID | None, Query(alias="session")] = None,
    limit: int = Query(100, ge=1, le=deck.ACTIVITY_LIST_MAX),
):
    return deck.list_activity(session, since, until, card_id, kind, session_id, limit)


def _call(operation, *args):
    """Runs a deck operation; not found → 404, a broken note rule → 422 `{"detail": message}`."""
    try:
        return operation(*args)
    except deck.NotFound as error:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(error)) from error
    except deck.InvalidNote as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error
