import json
from datetime import UTC, date, datetime
from enum import StrEnum
from typing import Any
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import fsrs
from pydantic import AwareDatetime, BaseModel, field_validator, model_validator
from pydantic import Field as PydanticField
from sqlmodel import JSON, Column, Field, ForeignKey, Index, SQLModel, Uuid

from la_carte_api.db import UTCDateTime


def utcnow() -> datetime:
    return datetime.now(UTC)


class Rating(StrEnum):
    again = "again"
    hard = "hard"
    good = "good"
    easy = "easy"

    def to_fsrs(self) -> fsrs.Rating:
        return fsrs.Rating[self.name.capitalize()]


class CardState(StrEnum):
    new = "new"
    learning = "learning"
    review = "review"
    relearning = "relearning"


class NoteType(StrEnum):
    basic = "basic"
    person = "person"


class ReportReason(StrEnum):
    wrong = "wrong"
    drop = "drop"
    doubt = "doubt"
    rephrase = "rephrase"
    other = "other"
    broken_photo = "broken_photo"  # filed by the app when a photo fails to load


class ReportStatus(StrEnum):
    open = "open"
    waiting_user = "waiting_user"
    resolved = "resolved"
    dismissed = "dismissed"


ACTIVE_REPORT = (ReportStatus.open, ReportStatus.waiting_user)  # these hold the card (spec 015)


class ReportOutcome(StrEnum):
    waiting_user = "waiting_user"
    fixed = "fixed"
    kept = "kept"
    deleted = "deleted"


class FeedbackKind(StrEnum):
    bug = "bug"
    confusing = "confusing"
    missing = "missing"
    friction = "friction"
    other = "other"


class FeedbackStatus(StrEnum):
    open = "open"
    done = "done"


class TokenKind(StrEnum):
    access = "access"
    refresh = "refresh"
    pat = "pat"


class TokenScope(StrEnum):
    deck = "deck"  # everything the user owns, REST and MCP
    stats = "stats"  # `GET /stats` only (the widget)


def owner_column() -> Any:
    """`user_id` of an owned row (spec 030a): indexed, required, no foreign key (`DELETE /me`
    deletes owned rows explicitly, like the review history that has no foreign key either)."""
    return Field(sa_column=Column("user_id", Uuid, nullable=False, index=True))


# --- Tables -----------------------------------------------------------------------------------


class User(SQLModel, table=True):
    """An account (spec 030a): one deck. No name, no picture, never a password."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    email: str = Field(unique=True)  # casefolded, verified by the identity provider
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    last_seen_at: datetime | None = Field(default=None, sa_type=UTCDateTime)


class Identity(SQLModel, table=True):
    """The provider account (Apple or Google `sub`) a user signs in with (spec 030b/e)."""

    provider: str = Field(primary_key=True)
    subject: str = Field(primary_key=True)
    user_id: UUID = Field(
        sa_column=Column(Uuid, ForeignKey("user.id", ondelete="CASCADE"), nullable=False)
    )
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    provider_token: str | None = None  # Apple's refresh token only, to revoke on deletion
    provider_client_id: str | None = None


class ApiToken(SQLModel, table=True):
    """One of our opaque tokens (access, refresh or personal); only its SHA-256 is stored."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(
        sa_column=Column(
            Uuid, ForeignKey("user.id", ondelete="CASCADE"), nullable=False, index=True
        )
    )
    kind: TokenKind
    hash: str = Field(unique=True)
    scope: TokenScope = TokenScope.deck
    name: str | None = None  # personal access tokens
    client_id: str | None = None
    family_id: UUID | None = None  # refresh rotation (spec 030b)
    expires_at: datetime | None = Field(default=None, sa_type=UTCDateTime)
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    last_used_at: datetime | None = Field(default=None, sa_type=UTCDateTime)
    revoked_at: datetime | None = Field(default=None, sa_type=UTCDateTime)


class Note(SQLModel, table=True):
    """One thing the user knows: typed, named fields (spec 014). Its cards are directions over
    those fields. One deck per user, so no deck id."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = owner_column()
    type: NoteType
    fields: dict[str, str] = Field(sa_column=Column(JSON, nullable=False))
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    updated_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)


class Card(SQLModel, table=True):
    """One direction over a note's fields (`prompt` fields -> `answer` fields, both in the type's
    field order) plus its own FSRS scheduling state. `user_id` is always its note's."""

    __table_args__ = (Index("ix_card_user_id_due", "user_id", "due"),)

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = owner_column()
    note_id: UUID = Field(
        sa_column=Column(
            Uuid, ForeignKey("note.id", ondelete="CASCADE"), nullable=False, index=True
        )
    )
    prompt: list[str] = Field(sa_column=Column(JSON, nullable=False))
    answer: list[str] = Field(sa_column=Column(JSON, nullable=False))
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    updated_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)

    # FSRS state, mirrors `fsrs.Card`.
    due: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime, index=True)
    fsrs_state: int = fsrs.State.Learning.value
    step: int | None = 0
    stability: float | None = None
    difficulty: float | None = None
    last_review: datetime | None = Field(default=None, sa_type=UTCDateTime)

    @property
    def state(self) -> CardState:
        if self.last_review is None:
            return CardState.new
        return CardState(fsrs.State(self.fsrs_state).name.lower())

    def to_fsrs(self) -> fsrs.Card:
        # A fixed card_id: without one, `fsrs.Card` sleeps 1 ms to make a unique id (unused here).
        return fsrs.Card(
            card_id=0,
            state=fsrs.State(self.fsrs_state),
            step=self.step,
            stability=self.stability,
            difficulty=self.difficulty,
            due=self.due,
            last_review=self.last_review,
        )

    def apply_fsrs(self, card: fsrs.Card) -> None:
        self.fsrs_state = card.state.value
        self.step = card.step
        self.stability = card.stability
        self.difficulty = card.difficulty
        self.due = card.due
        self.last_review = card.last_review


class ReviewLog(SQLModel, table=True):
    """One review. Never deleted: `card_id` has no foreign key so the history (streak,
    reviewed_today) survives deleting the card (spec 012)."""

    id: int | None = Field(default=None, primary_key=True)
    user_id: UUID = owner_column()
    card_id: UUID = Field(sa_column=Column(Uuid, nullable=False, index=True))
    rating: Rating
    reviewed_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime, index=True)
    confidence: float | None = None  # measured 0-1 drag value (spec 013); not used by FSRS
    # The card's memory state just before this review; null when it was new (spec 021).
    stability_before: float | None = None
    last_review_before: datetime | None = Field(default=None, sa_type=UTCDateTime)


class Report(SQLModel, table=True):
    """The user flagged a card while studying (spec 015). While `open` or `waiting_user` the card
    is held out of study. `card_id` / `note_id` have no foreign key: a report outlives its card."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = owner_column()
    card_id: UUID = Field(sa_column=Column(Uuid, nullable=False, index=True))
    note_id: UUID = Field(sa_column=Column(Uuid, nullable=False))
    reason: ReportReason
    comment: str | None = None
    status: ReportStatus = ReportStatus.open
    resolution: str | None = None  # the agent's last note: its question, or what it did
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    updated_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    resolved_at: datetime | None = Field(default=None, sa_type=UTCDateTime)


class Feedback(SQLModel, table=True):
    """An agent's feedback to the developer who runs this server (spec 025). Never touches the
    deck; closed once with an optional `resolution`."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = owner_column()
    kind: FeedbackKind = FeedbackKind.other
    message: str
    status: FeedbackStatus = FeedbackStatus.open
    resolution: str | None = None
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    closed_at: datetime | None = Field(default=None, sa_type=UTCDateTime)


class Settings(SQLModel, table=True):
    """A user's deck settings (spec 021, keyed by user since 030a). No row = the defaults."""

    user_id: UUID = Field(primary_key=True)
    new_cards_per_day: int = 15  # the new-card milestone size M (1-200; a stored 0 reads 15)


class ActivityEvent(SQLModel, table=True):
    """Something the user did in the app (spec 029), sent lazily by the app. `id` is the
    client's UUID (ingest is idempotent on it); `card_id` has no foreign key."""

    id: UUID = Field(primary_key=True)
    user_id: UUID = owner_column()
    kind: str = Field(index=True)
    at: datetime = Field(sa_type=UTCDateTime, index=True)  # device clock, stored in UTC
    tz: str
    session: UUID
    card_id: UUID | None = Field(default=None, sa_column=Column(Uuid, index=True))
    app_version: str
    build: str
    os: str
    data: dict[str, Any] = Field(default_factory=dict, sa_column=Column(JSON, nullable=False))
    received_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)  # server clock


# --- Public schemas (REST + MCP) ---------------------------------------------------------------


class CardCreate(BaseModel):
    front: str = PydanticField(min_length=1, description="Prompt side of the card.")
    back: str = PydanticField(min_length=1, description="Answer side of the card.")


class CardUpdate(BaseModel):
    front: str | None = PydanticField(default=None, min_length=1)
    back: str | None = PydanticField(default=None, min_length=1)


class CardRead(BaseModel):
    """A card with its note's data. `front` / `back` are the prompt / answer field values joined
    by a newline, for clients that predate notes (spec 014)."""

    id: UUID
    note_id: UUID
    type: NoteType
    prompt: list[str]
    answer: list[str]
    fields: dict[str, str]  # the whole note's fields
    front: str
    back: str
    state: CardState
    due: datetime
    last_review: datetime | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, card: Card, note: Note) -> "CardRead":
        def side(names: list[str]) -> str:
            return "\n".join(note.fields[name] for name in names if name in note.fields)

        return cls(
            id=card.id,
            note_id=note.id,
            type=note.type,
            prompt=card.prompt,
            answer=shown(card.answer, note),
            fields=note.fields,
            front=side(card.prompt),
            back=side(card.answer),
            state=card.state,
            due=card.due,
            last_review=card.last_review,
            created_at=card.created_at,
            updated_at=max(card.updated_at, note.updated_at),
        )


def shown(answer: list[str], note: Note) -> list[str]:
    """A card's answer as shown: its fields that are set (a person's answer is stored whole)."""
    return [name for name in answer if name in note.fields]


class Direction(BaseModel):
    prompt: list[str] = PydanticField(
        description='The one field shown as the question, e.g. ["photo"].'
    )
    answer: list[str] | None = PydanticField(
        default=None,
        description="Fields to recall: always every other field of the note (empty ones are "
        'left out when shown), e.g. ["name", "description"]. May be omitted.',
    )


class NoteCreate(BaseModel):
    type: NoteType = PydanticField(description="basic or person.")
    fields: dict[str, str] = PydanticField(
        description="basic: front, back (both required). person: photo (public http(s) URL), "
        'name (required), description (free text, e.g. "Mistral CEO").'
    )
    directions: list[Direction] | None = PydanticField(
        default=None,
        description="The cards to create, one per prompt field. Omit for basic (both: front -> "
        "back and back -> front; pass one only when the reverse isn't a meaningful question); "
        "required for person: any of photo, name, description as prompt.",
    )


class NoteUpdate(BaseModel):
    fields: dict[str, str] | None = PydanticField(
        default=None, description="Merged key by key; an empty string clears a field."
    )
    directions: list[Direction] | None = PydanticField(
        default=None,
        description="The full desired set: kept directions keep their card and schedule, new "
        "ones become cards due now, missing ones are deleted (review history kept).",
    )


class NoteCard(BaseModel):
    id: UUID
    prompt: list[str]
    answer: list[str]
    state: CardState
    due: datetime
    last_review: datetime | None


class NoteNext(BaseModel):
    """The card of a note Study serves first, and when (spec 028)."""

    card_id: UUID
    ready_at: datetime


class NoteRead(BaseModel):
    id: UUID
    type: NoteType
    fields: dict[str, str]
    cards: list[NoteCard]
    next: NoteNext | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, note: Note, cards: list[Card], next: NoteNext | None) -> "NoteRead":
        return cls(
            id=note.id,
            type=note.type,
            fields=note.fields,
            cards=[
                NoteCard(
                    id=c.id,
                    prompt=c.prompt,
                    answer=shown(c.answer, note),
                    state=c.state,
                    due=c.due,
                    last_review=c.last_review,
                )
                for c in cards
            ],
            next=next,
            created_at=note.created_at,
            updated_at=note.updated_at,
        )


class ReviewCreate(BaseModel):
    rating: Rating
    confidence: float | None = PydanticField(
        default=None, ge=0, le=1, description="Measured 0-1 confidence; stored, not scheduled."
    )


class DeckStats(BaseModel):
    total: int  # cards, not notes
    due: int  # size of the servable queue (sibling burying applied, spec 014)
    new: int
    reviewed_today: int
    next_due: datetime | None  # earliest time after now a card becomes servable; null if none
    new_today: int  # distinct cards first reviewed today (local day in tz), from ReviewLog (021)
    milestone: int  # the new-card milestone size M, 1-200 (spec 021)
    streak: int  # days in the current run, frozen days included (spec 024 decision 4)
    streak_start: date | None  # the run's first local day; null when streak = 0
    history_start: date  # the first local review day, or today when there are none
    # One letter per local day from history_start to today: s studied, f frozen, m missed,
    # p today not yet studied (spec 024).
    history: str
    due_new: int  # never-reviewed cards in the servable queue (a subset of `due`)
    # The app's daily ladder (spec 021 decision 5), display only: nothing is held back.
    at_risk_total: int  # 0 when the at-risk step doesn't exist today (fewer than AT_RISK_MIN)
    at_risk_done: int
    reviews_total: int
    reviews_done: int  # = reviewed_today - new_today


class ReviewEntry(BaseModel):
    """MCP `review_history` (spec 031): one `ReviewLog` row with the card as it is now."""

    card_id: UUID
    reviewed_at: datetime  # UTC
    rating: Rating
    confidence: float | None
    card: CardRead | None  # null once the card was deleted


class StrugglingCard(BaseModel):
    """MCP `struggling_cards` (spec 031): an existing card's `again` count in the window."""

    card: CardRead
    reviews: int  # all ratings of the card in the window
    again: int
    last_again_at: datetime  # UTC


class MilestoneSetting(BaseModel):
    """MCP `new_card_milestone`: the size of the new-card steps the app shows (spec 021)."""

    milestone: int


class AddCardsResult(BaseModel):
    added: list[CardRead]
    skipped: list[CardRead]  # existing cards whose front matched


class AddNotesResult(BaseModel):
    added: list[NoteRead]
    skipped: list[NoteRead]  # existing notes whose duplicate key matched


class AddNotesReply(AddNotesResult):
    """MCP only: never-reviewed cards after the insert, and the milestone size."""

    new: int
    milestone: int


class ReportCreate(BaseModel):
    reason: ReportReason
    comment: str | None = PydanticField(
        default=None, description="Trimmed, 1-500 chars; required when the reason is other."
    )

    @field_validator("comment")
    @classmethod
    def _trimmed(cls, comment: str | None) -> str | None:
        comment = (comment or "").strip() or None
        if comment and len(comment) > 500:
            raise ValueError("comment is at most 500 characters")
        return comment

    @model_validator(mode="after")
    def _other_needs_comment(self) -> "ReportCreate":
        if self.reason == ReportReason.other and self.comment is None:
            raise ValueError("a comment is required when the reason is other")
        return self


class ReportRead(BaseModel):
    id: UUID
    card_id: UUID
    note_id: UUID
    reason: ReportReason
    comment: str | None
    status: ReportStatus
    resolution: str | None
    created_at: datetime
    updated_at: datetime
    resolved_at: datetime | None
    card: CardRead | None  # null once the card is deleted

    @classmethod
    def of(cls, report: Report, card: CardRead | None) -> "ReportRead":
        return cls(**report.model_dump(), card=card)


class FeedbackRead(BaseModel):
    id: UUID
    user_email: str  # who sent it (spec 030a: only the owner sees other users' feedback)
    kind: FeedbackKind
    message: str
    status: FeedbackStatus
    resolution: str | None
    created_at: datetime
    closed_at: datetime | None


ACTIVITY_DATA_MAX = 4096  # bytes of an event's serialized `data`


class ActivityEventIn(BaseModel):
    """One event as the app sends it (spec 029). Validated on its own: a bad one is skipped."""

    id: UUID
    kind: str = PydanticField(pattern=r"^[a-z][a-z_]{0,39}$")
    at: AwareDatetime
    tz: str = PydanticField(max_length=64)
    session: UUID
    app_version: str = PydanticField(max_length=32)
    build: str = PydanticField(max_length=32)
    os: str = PydanticField(max_length=32)
    card_id: UUID | None = None
    data: dict[str, Any] = PydanticField(default_factory=dict)

    @field_validator("at")
    @classmethod
    def _to_utc(cls, value: datetime) -> datetime:
        return value.astimezone(UTC)

    @field_validator("tz")
    @classmethod
    def _known_zone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError, OSError) as error:
            raise ValueError(f"unknown time zone {value!r}") from error
        return value

    @field_validator("data")
    @classmethod
    def _small_data(cls, value: dict[str, Any]) -> dict[str, Any]:
        if len(json.dumps(value, separators=(",", ":")).encode()) > ACTIVITY_DATA_MAX:
            raise ValueError(f"data is at most {ACTIVITY_DATA_MAX} bytes")
        return value


class ActivityBatch(BaseModel):
    events: list[Any]  # each element validated on its own (`ActivityEventIn`)


class ActivityIngest(BaseModel):
    stored: int
    duplicates: int
    rejected: int


class ActivityEventRead(BaseModel):
    id: UUID
    kind: str
    at: datetime  # UTC
    local_at: datetime  # `at` in `tz`, with its offset
    tz: str
    session: UUID
    card_id: UUID | None
    app_version: str
    build: str
    os: str
    data: dict[str, Any]
    received_at: datetime

    @classmethod
    def of(cls, event: ActivityEvent) -> "ActivityEventRead":
        local_at = event.at.astimezone(ZoneInfo(event.tz))
        return cls(**event.model_dump(), local_at=local_at)


# --- Accounts (spec 030a) ----------------------------------------------------------------------


class MeRead(BaseModel):
    id: UUID
    email: str
    provider: str | None  # "apple" | "google"; null for the migrated owner before sign-in
    created_at: datetime


class PersonalToken(BaseModel):
    """A personal access token as listed: never the token itself, nor its hash."""

    id: UUID
    name: str | None
    scope: TokenScope
    created_at: datetime
    expires_at: datetime | None
    last_used_at: datetime | None
