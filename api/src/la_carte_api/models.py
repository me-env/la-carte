from datetime import UTC, datetime
from enum import StrEnum
from uuid import UUID, uuid4

import fsrs
from pydantic import BaseModel
from pydantic import Field as PydanticField
from sqlmodel import JSON, Column, Field, ForeignKey, SQLModel, Uuid

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


# --- Tables -----------------------------------------------------------------------------------


class Note(SQLModel, table=True):
    """One thing the user knows: typed, named fields (spec 014). Its cards are directions over
    those fields. There is a single deck, so no deck id."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    type: NoteType
    fields: dict[str, str] = Field(sa_column=Column(JSON, nullable=False))
    created_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)
    updated_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime)


class Card(SQLModel, table=True):
    """One direction over a note's fields (`prompt` fields -> `answer` fields, both in the type's
    field order) plus its own FSRS scheduling state."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
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
        return fsrs.Card(
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
    card_id: UUID = Field(sa_column=Column(Uuid, nullable=False, index=True))
    rating: Rating
    reviewed_at: datetime = Field(default_factory=utcnow, sa_type=UTCDateTime, index=True)
    confidence: float | None = None  # measured 0-1 drag value (spec 013); not used by FSRS


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
        description="The cards to create, one per prompt field. Omit for basic (front -> back "
        "only); required for person: any of photo, name, description as prompt.",
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


class NoteRead(BaseModel):
    id: UUID
    type: NoteType
    fields: dict[str, str]
    cards: list[NoteCard]
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, note: Note, cards: list[Card]) -> "NoteRead":
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
    streak: int  # consecutive local days with a review, ending today or yesterday (spec 007)


class AddCardsResult(BaseModel):
    added: list[CardRead]
    skipped: list[CardRead]  # existing cards whose front matched


class AddNotesResult(BaseModel):
    added: list[NoteRead]
    skipped: list[NoteRead]  # existing notes whose duplicate key matched
