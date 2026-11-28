"""REST API consumed by the iOS app."""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Response, status

from la_carte_api import auth, deck
from la_carte_api.auth import AppUser, CurrentUser, SessionDep, StatsUser
from la_carte_api.models import (
    ActivityBatch,
    ActivityEventRead,
    ActivityIngest,
    CardCreate,
    CardRead,
    CardUpdate,
    DeckStats,
    MeRead,
    NoteCreate,
    NoteRead,
    NoteType,
    NoteUpdate,
    PersonalToken,
    PersonalTokenCreate,
    PersonalTokenCreated,
    ReportCreate,
    ReportRead,
    ReviewCreate,
)

router = APIRouter()


# --- Notes (spec 014a) -------------------------------------------------------------------------


@router.get("/notes", response_model=list[NoteRead])
def list_notes(
    session: SessionDep,
    user: CurrentUser,
    query: str | None = None,
    type: NoteType | None = None,
    limit: int = Query(100, le=500),
):
    return deck.list_notes(session, user, query, type, limit)


@router.post("/notes", response_model=NoteRead, status_code=status.HTTP_201_CREATED)
def add_note(session: SessionDep, user: CurrentUser, body: NoteCreate):
    return _call(deck.add_notes, session, user, [body]).added[0]


@router.get("/notes/{note_id}", response_model=NoteRead)
def get_note(session: SessionDep, user: CurrentUser, note_id: UUID):
    return _call(deck.get_note, session, user, note_id)


@router.patch("/notes/{note_id}", response_model=NoteRead)
def update_note(session: SessionDep, user: CurrentUser, note_id: UUID, body: NoteUpdate):
    return _call(deck.update_note, session, user, note_id, body)


@router.delete("/notes/{note_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_note(session: SessionDep, user: CurrentUser, note_id: UUID):
    _call(deck.delete_note, session, user, note_id)


# --- Cards -------------------------------------------------------------------------------------


@router.get("/cards", response_model=list[CardRead])
def list_cards(
    session: SessionDep,
    user: CurrentUser,
    query: str | None = None,
    limit: int = Query(100, le=500),
):
    return deck.list_cards(session, user, query, limit)


@router.post("/cards", response_model=CardRead, status_code=status.HTTP_201_CREATED)
def add_card(session: SessionDep, user: CurrentUser, body: CardCreate):
    return _call(deck.add_cards, session, user, [body]).added[0]


@router.get("/cards/due", response_model=list[CardRead])
def due_cards(session: SessionDep, user: CurrentUser, limit: int = Query(20, le=200)):
    return deck.due_cards(session, user, limit)


@router.get("/cards/{card_id}", response_model=CardRead)
def get_card(session: SessionDep, user: CurrentUser, card_id: UUID):
    return _call(deck.get_card, session, user, card_id)


@router.patch("/cards/{card_id}", response_model=CardRead)
def update_card(session: SessionDep, user: CurrentUser, card_id: UUID, body: CardUpdate):
    return _call(deck.update_card, session, user, card_id, body)


@router.delete("/cards/{card_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_card(session: SessionDep, user: CurrentUser, card_id: UUID):
    _call(deck.delete_card, session, user, card_id)


@router.post("/cards/{card_id}/review", response_model=CardRead)
def review_card(session: SessionDep, user: CurrentUser, card_id: UUID, body: ReviewCreate):
    return _call(deck.review_card, session, user, card_id, body.rating, None, body.confidence)


@router.post(
    "/cards/{card_id}/report", response_model=ReportRead, status_code=status.HTTP_201_CREATED
)
def report_card(
    session: SessionDep, user: CurrentUser, card_id: UUID, body: ReportCreate, response: Response
):
    """Holds the card out of study until an agent closes the report (spec 015).
    An already active `broken_photo` report is returned with 200 instead of a new one."""
    report, created = _call(deck.report_card, session, user, card_id, body)
    if not created:
        response.status_code = status.HTTP_200_OK
    return report


@router.get("/stats", response_model=DeckStats)
def stats(session: SessionDep, user: StatsUser, tz: str = "UTC"):
    """`tz`: IANA time zone defining the local days of `reviewed_today`, `new_today`, `streak`
    and `history`."""
    try:
        zone = deck.time_zone(tz)
    except deck.UnknownTimeZone as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error
    return deck.stats(session, user, tz=zone)


# --- Account (spec 030a) ----------------------------------------------------------------------


@router.get("/me", response_model=MeRead)
def get_me(session: SessionDep, user: CurrentUser):
    return deck.me(session, user)


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT)
def delete_me(session: SessionDep, user: CurrentUser):
    """Deletes the account and everything it owns, at once (App Store 5.1.1(v))."""
    deck.delete_account(session, user)


@router.get("/me/tokens", response_model=list[PersonalToken])
def list_tokens(session: SessionDep, user: CurrentUser):
    return auth.list_personal_tokens(session, user)


@router.post("/me/tokens", response_model=PersonalTokenCreated, status_code=status.HTTP_201_CREATED)
def create_token(session: SessionDep, user: AppUser, body: PersonalTokenCreate):
    """A personal access token, shown once. Only from the app (an `la-carte-ios` access
    token): a PAT or an agent's token gets 403."""
    try:
        return auth.create_personal_token(session, user, body)
    except auth.TooManyTokens as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error


@router.delete("/me/tokens/{token_id}", status_code=status.HTTP_204_NO_CONTENT)
def revoke_token(session: SessionDep, user: CurrentUser, token_id: UUID):
    try:
        auth.revoke_personal_token(session, user, token_id)
    except auth.TokenNotFound as error:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(error)) from error


# --- Activity (spec 029) ----------------------------------------------------------------------


@router.post("/activity", response_model=ActivityIngest)
def post_activity(session: SessionDep, user: CurrentUser, body: ActivityBatch):
    """The app's activity events; each is validated on its own (invalid ones are `rejected`)."""
    try:
        return deck.ingest_activity(session, user, body.events)
    except deck.TooManyEvents as error:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, str(error)) from error


@router.get("/activity", response_model=list[ActivityEventRead])
def list_activity(
    session: SessionDep,
    user: CurrentUser,
    since: datetime | None = None,
    until: datetime | None = None,
    card_id: UUID | None = None,
    kind: str | None = None,
    session_id: Annotated[UUID | None, Query(alias="session")] = None,
    limit: int = Query(100, ge=1, le=deck.ACTIVITY_LIST_MAX),
):
    return deck.list_activity(session, user, since, until, card_id, kind, session_id, limit)


def _call(operation, *args):
    """Runs a deck operation; not found → 404, a broken note rule → 422 `{"detail": message}`."""
    try:
        return operation(*args)
    except deck.NotFound as error:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(error)) from error
    except deck.InvalidNote as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from error
