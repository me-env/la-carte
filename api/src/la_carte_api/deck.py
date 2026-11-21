"""The deck: every operation on notes and cards. REST routes and MCP tools are thin wrappers.

A note is one thing the user knows (typed, named fields); a card is one direction over its fields
(prompt fields -> answer fields) with its own FSRS state. Cards of a note are siblings (spec 014).
Public functions return the read schemas (`NoteRead`, `CardRead`) shared by REST and MCP.
"""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta, tzinfo
from itertools import islice
from urllib.parse import urlsplit
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import fsrs
from sqlmodel import Session, col, delete, func, select

from la_carte_api.models import (
    AddCardsResult,
    AddNotesResult,
    Card,
    CardCreate,
    CardRead,
    CardUpdate,
    DeckStats,
    Direction,
    Note,
    NoteCreate,
    NoteRead,
    NoteType,
    NoteUpdate,
    Rating,
    ReviewLog,
    utcnow,
)

_scheduler = fsrs.Scheduler()
_DAY = timedelta(days=1)

# After any card of a note is reviewed, its siblings are not served for this long (user decision).
SIBLING_BURY = timedelta(hours=6)

Side = tuple[str, ...]  # field names, in the type's field order
Way = tuple[Side, Side]  # (prompt, answer): a direction, normalized


@dataclass(frozen=True)
class NoteKind:
    fields: Side  # display order
    required: frozenset[str]
    key: str  # duplicate key for `add_notes`
    default_directions: tuple[Way, ...]
    directions_hint: str  # shown when directions are missing


NOTE_TYPES: dict[NoteType, NoteKind] = {
    NoteType.basic: NoteKind(
        fields=("front", "back"),
        required=frozenset({"front", "back"}),
        key="front",
        default_directions=((("front",), ("back",)),),
        directions_hint="e.g. front -> back",
    ),
    NoteType.person: NoteKind(
        fields=("photo", "name", "description"),
        required=frozenset({"name"}),
        key="name",
        default_directions=(),
        directions_hint="photo -> name + description, name -> photo + description, "
        "description -> name + photo",
    ),
}

# Person fields removed by spec 014a's amendment, both folded into `description`.
REMOVED_FIELDS: dict[NoteType, Side] = {NoteType.person: ("role", "context")}


class NotFound(LookupError):
    pass


class CardNotFound(NotFound):
    def __init__(self, card_id: UUID) -> None:
        super().__init__(f"No card with id {card_id}")


class NoteNotFound(NotFound):
    def __init__(self, note_id: UUID) -> None:
        super().__init__(f"No note with id {note_id}")


class InvalidNote(ValueError):
    """A note, its fields or its directions break a rule. The message is written for an LLM
    reader and names the field or direction, never a field's value (photos are private)."""


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


# --- Validation (spec 014a rules 1-7) ----------------------------------------------------------


def _show(way: Way) -> str:
    prompt, answer = way
    return f"{' + '.join(prompt) or '(nothing)'} -> {' + '.join(answer) or '(nothing)'}"


def _clean_fields(note_type: NoteType, fields: dict[str, str]) -> dict[str, str]:
    """Trimmed values in the type's field order; an empty value means absent (rules 1-4)."""
    kind = NOTE_TYPES[note_type]
    for name in fields:
        _check_not_removed(note_type, name)
        if name not in kind.fields:
            raise InvalidNote(
                f"Unknown field {name!r} for a {note_type} note; its fields are: "
                f"{', '.join(kind.fields)}."
            )
    cleaned = {name: fields[name].strip() for name in kind.fields if name in fields}
    cleaned = {name: value for name, value in cleaned.items() if value}
    for name in kind.fields:
        if name in kind.required and name not in cleaned:
            raise InvalidNote(f"A {note_type} note needs the field {name!r}.")
    if "photo" in cleaned and not _is_http_url(cleaned["photo"]):
        raise InvalidNote("Field 'photo' must be a public http(s) URL, e.g. https://…/photo.jpg.")
    return cleaned


def _is_http_url(value: str) -> bool:
    try:
        parts = urlsplit(value)
        return parts.scheme in ("http", "https") and bool(parts.hostname)
    except ValueError:  # e.g. a malformed IPv6 host
        return False


def _check_not_removed(note_type: NoteType, name: str) -> None:
    if name in REMOVED_FIELDS.get(note_type, ()):
        raise InvalidNote(
            f"Field {name!r} no longer exists for a {note_type} note: use description."
        )


def _way(note_type: NoteType, direction: Direction, fields: dict[str, str]) -> Way:
    """A direction checked and normalized (rule 5, amended): exactly one prompt field; the answer
    is every other field of the type, stored whole so a field set later shows up (empty ones are
    left out when shown). A given answer must be those fields: all of them, or the set ones."""
    kind = NOTE_TYPES[note_type]
    answer = direction.answer or []
    shown = _show((tuple(direction.prompt), tuple(answer)))
    for name in direction.prompt + answer:
        _check_not_removed(note_type, name)
        if name not in kind.fields:
            raise InvalidNote(
                f"Direction {shown}: unknown field {name!r}; a {note_type} note's fields are: "
                f"{', '.join(kind.fields)}."
            )
    if len(direction.prompt) != 1:
        raise InvalidNote(
            f"Direction {shown}: the prompt is exactly one field ({kind.directions_hint})."
        )
    rest = tuple(f for f in kind.fields if f not in direction.prompt)
    way = (tuple(direction.prompt), rest)
    if direction.answer is not None and set(answer) not in (
        set(rest),
        {f for f in rest if f in fields},
    ):
        raise InvalidNote(f"Direction {shown}: the answer is every other field: {_show(way)}.")
    return way


def _ways(
    note_type: NoteType, directions: list[Direction] | None, fields: dict[str, str]
) -> list[Way]:
    """The note's directions: given ones, or the type's default when None (rules 5 and 7)."""
    kind = NOTE_TYPES[note_type]
    if directions is None:
        if not kind.default_directions:
            raise InvalidNote(
                f"Choose directions for this {note_type} note ({kind.directions_hint}): "
                "which field to show; the others are recalled."
            )
        return list(kind.default_directions)
    ways: list[Way] = []
    for direction in directions:
        way = _way(note_type, direction, fields)
        if way in ways:
            raise InvalidNote(f"Direction {_show(way)} is listed twice.")
        ways.append(way)
    if not ways:
        raise InvalidNote("A note needs at least one direction (a prompt field).")
    return ways


def _check_ways_use_fields(ways: Iterable[Way], fields: dict[str, str]) -> None:
    """Every direction's prompt field is set, and at least one of its answer fields (rule 6)."""
    for way in ways:
        prompt, answer = way
        for name in prompt:
            if name not in fields:
                raise InvalidNote(
                    f"Direction {_show(way)} uses field {name!r}, which is empty: set the "
                    "field, or remove the direction first."
                )
        if not any(name in fields for name in answer):
            raise InvalidNote(
                f"Direction {_show(way)} has nothing to recall: set {' or '.join(answer)}, "
                "or remove the direction first."
            )


# --- Reading -----------------------------------------------------------------------------------


def _way_of(card: Card) -> Way:
    return tuple(card.prompt), tuple(card.answer)


def _card_order(card: Card, note: Note) -> tuple:
    """Oldest first; cards created together follow the type's field order."""
    fields = NOTE_TYPES[note.type].fields
    prompt, answer = _way_of(card)
    return card.created_at, [fields.index(f) for f in prompt], [fields.index(f) for f in answer]


def _note(session: Session, note_id: UUID) -> Note:
    note = session.get(Note, note_id)
    if note is None:
        raise NoteNotFound(note_id)
    return note


def _card(session: Session, card_id: UUID) -> Card:
    card = session.get(Card, card_id)
    if card is None:
        raise CardNotFound(card_id)
    return card


def _cards_of(session: Session, note: Note) -> list[Card]:
    cards = session.exec(select(Card).where(Card.note_id == note.id))
    return sorted(cards, key=lambda card: _card_order(card, note))


def _note_reads(session: Session, notes: list[Note]) -> list[NoteRead]:
    cards: dict[UUID, list[Card]] = {note.id: [] for note in notes}
    for card in session.exec(select(Card).where(col(Card.note_id).in_(list(cards)))):
        cards[card.note_id].append(card)
    return [
        NoteRead.of(note, sorted(cards[note.id], key=lambda c, n=note: _card_order(c, n)))
        for note in notes
    ]


def _matches(note: Note, needle: str) -> bool:
    """`needle` (trimmed, casefolded) is a substring of a field other than `photo`.

    Matched in Python, not SQL: SQLite's LIKE only folds ASCII case ("été" must find "Été")."""
    return any(needle in value.casefold() for name, value in note.fields.items() if name != "photo")


def list_notes(
    session: Session, query: str | None = None, type: NoteType | None = None, limit: int = 100
) -> list[NoteRead]:
    """Newest first, optionally filtered by `type` and by `query` (see `_matches`)."""
    statement = select(Note).order_by(col(Note.created_at).desc())
    if type is not None:
        statement = statement.where(Note.type == type)
    needle = (query or "").strip().casefold()
    notes = (note for note in session.exec(statement) if _matches(note, needle))
    return _note_reads(session, list(islice(notes, limit)))


def get_note(session: Session, note_id: UUID) -> NoteRead:
    return _note_reads(session, [_note(session, note_id)])[0]


def list_cards(session: Session, query: str | None = None, limit: int = 100) -> list[CardRead]:
    """Newest first: cards whose note matches `query` (same matching as `list_notes`)."""
    statement = (
        select(Card, Note)
        .join(Note, col(Card.note_id) == col(Note.id))
        .order_by(col(Card.created_at).desc())
    )
    needle = (query or "").strip().casefold()
    rows = ((card, note) for card, note in session.exec(statement) if _matches(note, needle))
    return [CardRead.of(card, note) for card, note in islice(rows, limit)]


def get_card(session: Session, card_id: UUID) -> CardRead:
    card = _card(session, card_id)
    return CardRead.of(card, _note(session, card.note_id))


# --- Writing notes -----------------------------------------------------------------------------


def _new_card(note: Note, way: Way, now: datetime) -> Card:
    prompt, answer = way
    return Card(
        note_id=note.id, prompt=list(prompt), answer=list(answer),
        created_at=now, updated_at=now, due=now,
    )  # fmt: skip


def _duplicate_key(note_type: NoteType, fields: dict[str, str]) -> tuple[NoteType, str]:
    return note_type, fields.get(NOTE_TYPES[note_type].key, "").strip().casefold()


def _add_notes(
    session: Session, notes: list[NoteCreate], now: datetime | None, skip_duplicates: bool
) -> tuple[list[Note], list[Note]]:
    """(added, skipped) notes; all or nothing: an invalid note raises before anything is saved."""
    now = now or utcnow()
    existing: dict[tuple[NoteType, str], Note] = {}  # duplicate key -> oldest note with it
    if skip_duplicates:  # a single personal deck: matching in Python is fine
        for note in session.exec(select(Note).order_by(col(Note.created_at))):
            existing.setdefault(_duplicate_key(note.type, note.fields), note)

    added: list[Note] = []
    skipped: list[Note] = []
    cards: list[Card] = []
    for i, new in enumerate(notes):
        try:
            fields = _clean_fields(new.type, new.fields)
            ways = _ways(new.type, new.directions, fields)
            _check_ways_use_fields(ways, fields)
        except InvalidNote as error:
            raise InvalidNote(f"Note {i + 1}: {error}" if len(notes) > 1 else str(error)) from None
        key = _duplicate_key(new.type, fields)
        if skip_duplicates and key in existing:
            skipped.append(existing[key])
            continue
        note = Note(type=new.type, fields=fields, created_at=now, updated_at=now)
        cards += [_new_card(note, way, now) for way in ways]
        existing[key] = note
        added.append(note)
    session.add_all(added)
    session.flush()  # notes before their cards (foreign key; there is no ORM relationship)
    session.add_all(cards)
    session.commit()
    return added, skipped


def add_notes(
    session: Session,
    notes: list[NoteCreate],
    now: datetime | None = None,
    skip_duplicates: bool = False,
) -> AddNotesResult:
    """Adds notes with their cards, due immediately. With `skip_duplicates`, a note whose type and
    duplicate key (basic: front, person: name; trimmed, casefolded) match an existing note or an
    earlier one of the same call is not added; the matching note is reported in `skipped`."""
    added, skipped = _add_notes(session, notes, now, skip_duplicates)
    return AddNotesResult(added=_note_reads(session, added), skipped=_note_reads(session, skipped))


def update_note(
    session: Session, note_id: UUID, changes: NoteUpdate, now: datetime | None = None
) -> NoteRead:
    """`fields` merge key by key ("" clears). `directions` is the full desired set: kept ones keep
    their card (id, FSRS state), new ones become cards due now, missing ones are deleted (their
    review history stays)."""
    now = now or utcnow()
    note = _note(session, note_id)
    cards = {_way_of(card): card for card in _cards_of(session, note)}
    fields = _clean_fields(note.type, {**note.fields, **(changes.fields or {})})
    if changes.directions is None:
        ways = list(cards)
    else:
        ways = _ways(note.type, changes.directions, fields)
    _check_ways_use_fields(ways, fields)

    note.fields = fields  # a new dict: JSON columns don't track in-place changes
    note.updated_at = now
    for way, card in cards.items():
        if way not in ways:
            session.delete(card)
    session.add_all(_new_card(note, way, now) for way in ways if way not in cards)
    session.commit()
    return get_note(session, note_id)


def add_direction(
    session: Session, note_id: UUID, direction: Direction, now: datetime | None = None
) -> NoteRead:
    """A new card for the note, due now."""
    note = _note(session, note_id)
    current = [_way_of(card) for card in _cards_of(session, note)]
    if (way := _way(note.type, direction, note.fields)) in current:
        raise InvalidNote(f"This note already has the direction {_show(way)}.")
    directions = [Direction(prompt=list(p), answer=list(a)) for p, a in [*current, way]]
    return update_note(session, note_id, NoteUpdate(directions=directions), now)


def remove_direction(session: Session, card_id: UUID) -> NoteRead:
    """Deletes one card of a note (its review history stays). Refuses the note's last card."""
    card = _card(session, card_id)
    note = _note(session, card.note_id)
    if len(_cards_of(session, note)) == 1:
        raise InvalidNote("This is the note's last card: delete the note instead (delete_note).")
    session.delete(card)
    session.commit()
    return get_note(session, note.id)


def delete_note(session: Session, note_id: UUID) -> None:
    """Deletes the note and all its cards. Their ReviewLog rows stay (no foreign key), so past
    study days still count for stats."""
    note = _note(session, note_id)
    session.exec(delete(Card).where(col(Card.note_id) == note.id))
    session.delete(note)
    session.commit()


# --- Cards (compatibility layer: front/back, spec 014a) ----------------------------------------


def add_cards(
    session: Session,
    cards: list[CardCreate],
    now: datetime | None = None,
    skip_duplicates: bool = False,
) -> AddCardsResult:
    """Adds `basic` notes `front -> back` and returns their cards. With `skip_duplicates`, a front
    matching an existing basic note's front (or an earlier card of the call), ignoring case and
    surrounding whitespace, is skipped and that note's first card is reported instead."""
    notes = [
        NoteCreate(type=NoteType.basic, fields={"front": c.front, "back": c.back}) for c in cards
    ]
    added, skipped = _add_notes(session, notes, now, skip_duplicates)

    def first_card(note: Note) -> CardRead:
        return CardRead.of(_cards_of(session, note)[0], note)

    return AddCardsResult(
        added=[first_card(n) for n in added], skipped=[first_card(n) for n in skipped]
    )


def update_card(session: Session, card_id: UUID, changes: CardUpdate) -> CardRead:
    """Edits what this card shows: `front` sets its prompt field, `back` its answer field, on the
    note (so siblings see it). A side showing several fields can't be edited this way."""
    card = _card(session, card_id)
    fields: dict[str, str] = {}
    for side, value, names in (
        ("front", changes.front, card.prompt),
        ("back", changes.back, card.answer),
    ):
        if value is None:
            continue
        if len(names) != 1:
            raise InvalidNote(
                f"This card's {side} shows several fields ({', '.join(names)}): edit the note "
                f"instead (PATCH /notes/{card.note_id}, or the update_note tool)."
            )
        fields[names[0]] = value
    update_note(session, card.note_id, NoteUpdate(fields=fields))
    return get_card(session, card_id)


def delete_card(session: Session, card_id: UUID) -> None:
    """Removes this direction; the note goes too if it was its last card. Review history stays."""
    card = _card(session, card_id)
    note = _note(session, card.note_id)
    if len(_cards_of(session, note)) == 1:
        delete_note(session, note.id)
    else:
        remove_direction(session, card_id)


# --- Studying ----------------------------------------------------------------------------------


def _queue(session: Session, now: datetime) -> tuple[list[tuple[Card, Note]], datetime | None]:
    """The servable queue and the next time a card not servable now becomes servable.

    A card is buried while a sibling was reviewed less than `SIBLING_BURY` ago (its own reviews
    don't bury it). Servable = due, not buried, most overdue first, at most one card per note."""
    recent: dict[UUID, datetime] = dict(
        session.exec(
            select(ReviewLog.card_id, func.max(ReviewLog.reviewed_at))
            .where(col(ReviewLog.reviewed_at) > now - SIBLING_BURY)
            .group_by(col(ReviewLog.card_id))
        ).all()
    )
    rows = session.exec(select(Card, Note).join(Note, col(Card.note_id) == col(Note.id))).all()
    sibling_reviews: dict[UUID, list[tuple[UUID, datetime]]] = {}
    for card, _ in rows:
        if card.id in recent:
            sibling_reviews.setdefault(card.note_id, []).append((card.id, recent[card.id]))

    servable: list[tuple[Card, Note]] = []
    served_notes: set[UUID] = set()
    later: list[datetime] = []
    for card, note in sorted(rows, key=lambda row: (row[0].due, *_card_order(*row))):
        others = [t for cid, t in sibling_reviews.get(card.note_id, []) if cid != card.id]
        ready_at = max([card.due, *(t + SIBLING_BURY for t in others)])
        if ready_at > now:
            later.append(ready_at)
        elif card.note_id not in served_notes:
            served_notes.add(card.note_id)
            servable.append((card, note))
    return servable, min(later, default=None)


def due_cards(session: Session, limit: int = 20, now: datetime | None = None) -> list[CardRead]:
    """The servable queue (see `_queue`): what can be studied now."""
    queue, _ = _queue(session, now or utcnow())
    return [CardRead.of(card, note) for card, note in queue[:limit]]


def review_card(
    session: Session,
    card_id: UUID,
    rating: Rating,
    now: datetime | None = None,
    confidence: float | None = None,
) -> CardRead:
    """Reschedules the card from `rating` alone; `confidence` (0-1, optional) is only stored.
    Its siblings are then buried for `SIBLING_BURY`."""
    now = now or utcnow()
    card = _card(session, card_id)
    scheduled, _ = _scheduler.review_card(card.to_fsrs(), rating.to_fsrs(), review_datetime=now)
    card.apply_fsrs(scheduled)
    session.add(ReviewLog(card_id=card.id, rating=rating, reviewed_at=now, confidence=confidence))
    session.commit()
    return get_card(session, card_id)


def stats(session: Session, now: datetime | None = None, tz: tzinfo = UTC) -> DeckStats:
    """Deck counts at `now`. `due` / `next_due` follow the servable queue (burying applied);
    `total` / `new` count cards; `reviewed_today` and `streak` use calendar days in `tz`."""
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
    queue, next_due = _queue(session, now)
    return DeckStats(
        total=count(),
        due=len(queue),
        new=count(col(Card.last_review).is_(None)),
        reviewed_today=reviewed_today,
        next_due=next_due,
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
