from datetime import UTC, datetime
from enum import StrEnum
from uuid import UUID, uuid4

import fsrs
from pydantic import BaseModel
from pydantic import Field as PydanticField
from sqlmodel import Column, Field, SQLModel, Uuid

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


# --- Tables -----------------------------------------------------------------------------------


class Card(SQLModel, table=True):
    """A flashcard plus its FSRS scheduling state. There is a single deck, so no deck id."""

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    front: str
    back: str
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


# --- Public schemas (REST + MCP) ---------------------------------------------------------------


class CardCreate(BaseModel):
    front: str = PydanticField(min_length=1, description="Prompt side of the card.")
    back: str = PydanticField(min_length=1, description="Answer side of the card.")


class CardUpdate(BaseModel):
    front: str | None = PydanticField(default=None, min_length=1)
    back: str | None = PydanticField(default=None, min_length=1)


class CardRead(BaseModel):
    id: UUID
    front: str
    back: str
    state: CardState
    due: datetime
    last_review: datetime | None
    created_at: datetime
    updated_at: datetime

    @classmethod
    def of(cls, card: Card) -> "CardRead":
        return cls(
            id=card.id,
            front=card.front,
            back=card.back,
            state=card.state,
            due=card.due,
            last_review=card.last_review,
            created_at=card.created_at,
            updated_at=card.updated_at,
        )


class ReviewCreate(BaseModel):
    rating: Rating


class DeckStats(BaseModel):
    total: int
    due: int
    new: int
    reviewed_today: int
    next_due: datetime | None  # earliest `due` strictly after now; null if no such card
    streak: int  # consecutive local days with a review, ending today or yesterday (spec 007)


class AddCardsResult(BaseModel):
    added: list[CardRead]
    skipped: list[CardRead]  # existing cards whose front matched
