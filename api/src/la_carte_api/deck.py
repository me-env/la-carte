"""The deck: every operation on notes and cards. REST routes and MCP tools are thin wrappers.

A note is one thing the user knows (typed, named fields); a card is one direction over its fields
(prompt fields -> answer fields) with its own FSRS state. Cards of a note are siblings (spec 014).
Public functions return the read schemas (`NoteRead`, `CardRead`) shared by REST and MCP.
"""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta, tzinfo
from itertools import islice
from random import Random
from typing import Literal
from urllib.parse import urlsplit
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import fsrs
from fsrs.scheduler import FUZZ_RANGES
from sqlmodel import Session, col, delete, func, select

from la_carte_api.models import (
    ACTIVE_REPORT,
    AddCardsResult,
    AddNotesResult,
    Card,
    CardCreate,
    CardRead,
    CardState,
    CardUpdate,
    DeckStats,
    Direction,
    Feedback,
    FeedbackKind,
    FeedbackRead,
    FeedbackStatus,
    Note,
    NoteCreate,
    NoteRead,
    NoteType,
    NoteUpdate,
    Rating,
    Report,
    ReportCreate,
    ReportOutcome,
    ReportRead,
    ReportReason,
    ReportStatus,
    ReviewLog,
    Settings,
    utcnow,
)

# Fuzz is ours: `review_card` spreads review dues toward lighter days (spec 023).
_scheduler = fsrs.Scheduler(enable_fuzzing=False)
_rng = Random()
_DAY = timedelta(days=1)

# After a card of a note is reviewed, its siblings are held for at most this long, and never past
# that card's own next due (user decision 2026-11-22: a weak note comes back sooner).
SIBLING_BURY = timedelta(hours=6)
LEARNING = (CardState.learning, CardState.relearning)  # never buried; wins within its note

# Spec 021: `Settings.new_cards_per_day` is the size M of the new-card steps the app shows
# (display only: nothing is held back). A stored 0 reads as the default.
MAX_MILESTONE = 200
DEFAULT_MILESTONE = 15
# The day's "At risk" step: started cards whose recall at local midnight was below
# AT_RISK_RECALL; the step exists only with at least AT_RISK_MIN of them (spec 021 decision 5.1).
AT_RISK_RECALL = 0.8
AT_RISK_MIN = 10

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


class ReportNotFound(NotFound):
    def __init__(self, report_id: UUID) -> None:
        super().__init__(f"No report with id {report_id}")


class InvalidReport(ValueError):
    pass


class FeedbackNotFound(NotFound):
    def __init__(self, feedback_id: UUID) -> None:
        super().__init__(f"No feedback with id {feedback_id}")


class InvalidFeedback(ValueError):
    pass


class InvalidNote(ValueError):
    """A note, its fields or its directions break a rule. The message is written for an LLM
    reader and names the field or direction, never a field's value (photos are private)."""


class InvalidSetting(ValueError):
    """A deck setting outside its range (e.g. the new-card milestone not in 1-200)."""


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

    A sibling's latest review at `t` buries a card until `min(t + SIBLING_BURY, sibling.due)`:
    never longer than until that sibling is due again (its own reviews don't bury it). The
    sibling's current `due` is the one set by that latest review. A (re)learning card is never
    buried: a card the user failed comes back at its own due. Servable = due, not buried, at most
    one card per note: the first in `order` (a (re)learning card, then the review most at risk of
    being forgotten, then the oldest new card). The queue keeps that same order.
    Held cards (an active report, spec 015) are left out entirely: they don't bury siblings."""
    held = set(
        session.exec(select(Report.card_id).where(col(Report.status).in_(ACTIVE_REPORT))).all()
    )
    recent: dict[UUID, datetime] = dict(
        session.exec(
            select(ReviewLog.card_id, func.max(ReviewLog.reviewed_at))
            .where(col(ReviewLog.reviewed_at) > now - SIBLING_BURY)
            .group_by(col(ReviewLog.card_id))
        ).all()
    )
    rows = [
        (card, note)
        for card, note in session.exec(
            select(Card, Note).join(Note, col(Card.note_id) == col(Note.id))
        )
        if card.id not in held
    ]
    # note -> [(recently reviewed card, the time until which it holds its siblings)]
    holds: dict[UUID, list[tuple[UUID, datetime]]] = {}
    for card, _ in rows:
        if card.id in recent:
            until = min(recent[card.id] + SIBLING_BURY, card.due)
            holds.setdefault(card.note_id, []).append((card.id, until))

    def ready_at(card: Card) -> datetime:
        if card.state in LEARNING:
            return card.due
        return max([card.due, *(t for cid, t in holds.get(card.note_id, []) if cid != card.id)])

    def order(row: tuple[Card, Note]) -> tuple:
        """(Re)learning by due, then reviews lowest retrievability first, then new cards oldest
        first (specs 021, 022). Ties: earlier due, then `_card_order`, then id."""
        card, note = row
        if card.state in LEARNING:
            group, risk = 0, 0.0
        elif card.state == CardState.review:
            group, risk = 1, _scheduler.get_card_retrievability(card.to_fsrs(), now)
        else:
            group, risk = 2, 0.0
        return group, risk, card.due, *_card_order(card, note), str(card.id)

    servable: list[tuple[Card, Note]] = []
    served_notes: set[UUID] = set()
    later: list[datetime] = []
    for card, note in sorted(rows, key=order):
        ready = ready_at(card)
        if ready > now:
            later.append(ready)
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
    rng: Random | None = None,
) -> CardRead:
    """Reschedules the card from `rating` alone; `confidence` (0-1, optional) is only stored.
    A review interval of 3+ days moves to a lighter nearby day (`_balanced_due`, spec 023).
    Its siblings are then buried until its new due, at most `SIBLING_BURY` (see `_queue`)."""
    now = now or utcnow()
    card = _card(session, card_id)
    log = ReviewLog(
        card_id=card.id,
        rating=rating,
        reviewed_at=now,
        confidence=confidence,
        stability_before=card.stability,  # the memory state before this review: null when new
        last_review_before=card.last_review,
    )
    scheduled, _ = _scheduler.review_card(card.to_fsrs(), rating.to_fsrs(), review_datetime=now)
    if scheduled.state == fsrs.State.Review:
        scheduled.due = _balanced_due(session, card.id, scheduled.due, now, rng or _rng)
    card.apply_fsrs(scheduled)
    session.add(log)
    session.commit()
    return get_card(session, card_id)


def _balance_window(interval: int) -> tuple[int, int]:
    """Days the due may move to around an FSRS `interval` (days): the library's fuzz window."""
    delta = 1.0 + sum(
        r["factor"] * max(min(float(interval), r["end"]) - r["start"], 0.0) for r in FUZZ_RANGES
    )
    hi = min(round(interval + delta), _scheduler.maximum_interval)
    return min(max(2, round(interval - delta)), hi), hi


def _day_weight(count: int, day: int) -> float:
    """Anki 24.11 load-balancer weight of moving to `day`, which has `count` other cards due."""
    return 1.0 if count == 0 else (1 / count) ** 2.15 * (1 / day) ** 3


def _day_loads(session: Session, card_id: UUID, now: datetime, lo: int, hi: int) -> dict[int, int]:
    """Other cards due on each day `k` in `lo..hi`, day `k` being `(now + (k-1) d, now + k d]`."""
    dues = session.exec(
        select(Card.due).where(
            col(Card.due) > now + (lo - 1) * _DAY,
            col(Card.due) <= now + hi * _DAY,
            col(Card.id) != card_id,
        )
    )
    loads = dict.fromkeys(range(lo, hi + 1), 0)
    for due in dues:
        loads[-((now - due) // _DAY)] += 1  # ceil((due - now) / 1 day)
    return loads


def _balanced_due(
    session: Session, card_id: UUID, due: datetime, now: datetime, rng: Random
) -> datetime:
    """FSRS's `due` moved within `_balance_window`, weighted toward days with fewer cards due."""
    interval = (due - now).days
    if interval < 3:
        return due
    loads = _day_loads(session, card_id, now, *_balance_window(interval))
    weights = [_day_weight(count, day) for day, count in loads.items()]
    return now + rng.choices(list(loads), weights)[0] * _DAY


def stats(session: Session, now: datetime | None = None, tz: tzinfo = UTC) -> DeckStats:
    """Deck counts at `now`. `due` / `next_due` / `due_new` follow the servable queue (burying
    applied); `total` / `new` count cards; `reviewed_today`, `new_today`, the ladder counts
    (`at_risk_*`, `reviews_*`), `streak` and `history` use calendar days in `tz` (specs 007, 021,
    024)."""
    now = now or utcnow()
    today = now.astimezone(tz).date()
    start_of_day, end_of_day = _local_midnight(today, tz), _local_midnight(today + _DAY, tz)

    first_today = _first_reviews_between(session, start_of_day, end_of_day)
    first_reviews = (
        select(func.min(ReviewLog.reviewed_at).label("first"))
        .group_by(col(ReviewLog.card_id))
        .subquery()
    )
    new_today = session.exec(
        select(func.count())
        .select_from(first_reviews)
        .where(first_reviews.c.first >= start_of_day, first_reviews.c.first < end_of_day)
    ).one()
    review_times = session.exec(
        select(ReviewLog.reviewed_at).where(col(ReviewLog.reviewed_at) < end_of_day)
    )
    history_start, history = _history({t.astimezone(tz).date() for t in review_times}, today)
    streak, streak_start = _streak(history, history_start)
    queue, next_due = _queue(session, now)
    at_risk_total, at_risk_done = _at_risk(session, first_today, start_of_day)
    reviews_done = len(first_today) - new_today
    reviews_waiting = sum(
        c.last_review is not None and c.last_review < start_of_day for c, _ in queue
    )
    return DeckStats(
        total=session.exec(select(func.count()).select_from(Card)).one(),
        due=len(queue),
        new=new_card_count(session),
        reviewed_today=len(first_today),
        next_due=next_due,
        new_today=new_today,
        milestone=get_milestone(session),
        streak=streak,
        streak_start=streak_start,
        history_start=history_start,
        history=history,
        due_new=sum(card.last_review is None for card, _ in queue),
        at_risk_total=at_risk_total,
        at_risk_done=at_risk_done,
        reviews_total=reviews_done + reviews_waiting,
        reviews_done=reviews_done,
    )


def new_card_count(session: Session) -> int:
    """Never-reviewed cards (report-held ones included)."""
    return session.exec(
        select(func.count()).select_from(Card).where(col(Card.last_review).is_(None))
    ).one()


def _first_reviews_between(
    session: Session, start: datetime, end: datetime
) -> dict[UUID, ReviewLog]:
    """card id -> its first review in `[start, end)`, deleted cards included."""
    logs = session.exec(
        select(ReviewLog)
        .where(col(ReviewLog.reviewed_at) >= start, col(ReviewLog.reviewed_at) < end)
        .order_by(col(ReviewLog.reviewed_at), col(ReviewLog.id))
    )
    first: dict[UUID, ReviewLog] = {}
    for log in logs:
        first.setdefault(log.card_id, log)
    return first


def _was_at_risk(stability: float | None, last_review: datetime | None, at: datetime) -> bool:
    """A started card whose FSRS recall at `at` was below `AT_RISK_RECALL`."""
    if stability is None or last_review is None:
        return False
    # A fixed card_id: without one, `fsrs.Card` sleeps 1 ms to make a unique id (unused here).
    memory = fsrs.Card(card_id=0, stability=stability, last_review=last_review)
    return _scheduler.get_card_retrievability(memory, at) < AT_RISK_RECALL


def _at_risk(
    session: Session, first_today: dict[UUID, ReviewLog], start_of_day: datetime
) -> tuple[int, int]:
    """(at_risk_total, at_risk_done) of the day's snapshot (spec 021 decision 5.1): the cards at
    risk at `start_of_day`. A card reviewed today is judged by the state stored with its first
    review today (done, even if deleted since); any other card by its current state (waiting,
    unless held by a report). (0, 0) when fewer than `AT_RISK_MIN`."""
    done = sum(
        _was_at_risk(log.stability_before, log.last_review_before, start_of_day)
        for log in first_today.values()
    )
    held = select(Report.card_id).where(col(Report.status).in_(ACTIVE_REPORT))
    started = session.exec(
        select(Card).where(col(Card.last_review).is_not(None), col(Card.id).not_in(held))
    )
    waiting = sum(
        card.id not in first_today and _was_at_risk(card.stability, card.last_review, start_of_day)
        for card in started
    )
    total = done + waiting
    return (total, done) if total >= AT_RISK_MIN else (0, 0)


# --- New-card milestone (spec 021) ---------------------------------------------------------------


def get_milestone(session: Session) -> int:
    """The size M of the new-card steps the app shows: the stored setting, 15 when missing or 0."""
    settings = session.get(Settings, 1)
    return (settings and settings.new_cards_per_day) or DEFAULT_MILESTONE


def set_milestone(session: Session, value: int) -> int:
    """Stores the new-card milestone size (1-200) for every client and returns it."""
    if not 1 <= value <= MAX_MILESTONE:
        raise InvalidSetting(f"new_card_milestone must be between 1 and {MAX_MILESTONE}.")
    settings = session.get(Settings, 1) or Settings()
    settings.new_cards_per_day = value
    session.add(settings)  # inserts row 1 the first time
    session.commit()
    return value


# --- Reports (spec 015) -----------------------------------------------------------------------


def _report_read(session: Session, report: Report) -> ReportRead:
    card = session.get(Card, report.card_id)
    return ReportRead.of(report, CardRead.of(card, _note(session, card.note_id)) if card else None)


def report_card(
    session: Session, card_id: UUID, body: ReportCreate, now: datetime | None = None
) -> tuple[ReportRead, bool]:
    """Opens a report on the card, which holds it out of study until the report is closed.
    Returns `(report, created)`: a `broken_photo` report is not duplicated while one is active."""
    now = now or utcnow()
    card = _card(session, card_id)
    if body.reason == ReportReason.broken_photo:
        active = session.exec(
            select(Report).where(
                Report.card_id == card.id,
                Report.reason == body.reason,
                col(Report.status).in_(ACTIVE_REPORT),
            )
        ).first()
        if active:
            return _report_read(session, active), False
    report = Report(
        card_id=card.id, note_id=card.note_id, reason=body.reason, comment=body.comment,
        created_at=now, updated_at=now,
    )  # fmt: skip
    session.add(report)
    session.commit()
    return _report_read(session, report), True


ReportFilter = Literal["active", "all"] | ReportStatus


def list_reports(session: Session, status: ReportFilter = "active") -> list[ReportRead]:
    """Oldest first. `active` = open + waiting_user."""
    statement = select(Report).order_by(col(Report.created_at))
    if status == "active":
        statement = statement.where(col(Report.status).in_(ACTIVE_REPORT))
    elif status != "all":
        statement = statement.where(Report.status == status)
    return [_report_read(session, report) for report in session.exec(statement)]


_OUTCOME_STATUS = {
    ReportOutcome.waiting_user: ReportStatus.waiting_user,
    ReportOutcome.fixed: ReportStatus.resolved,
    ReportOutcome.kept: ReportStatus.dismissed,
    ReportOutcome.deleted: ReportStatus.resolved,
}


def update_report(
    session: Session,
    report_id: UUID,
    outcome: ReportOutcome,
    note: str,
    now: datetime | None = None,
) -> ReportRead:
    """Records the agent's `note` as `resolution` and applies `outcome` (see `_OUTCOME_STATUS`).
    `deleted` deletes the card like `delete_card` (if it still exists). The card's schedule is
    never touched."""
    now = now or utcnow()
    report = session.get(Report, report_id)
    if report is None:
        raise ReportNotFound(report_id)
    if report.status not in ACTIVE_REPORT:
        raise InvalidReport(f"Report {report_id} is already {report.status}.")
    if not note.strip():
        raise InvalidReport("`note` is required: your question, or what you did.")
    report.status = _OUTCOME_STATUS[outcome]
    report.resolution = note.strip()
    report.updated_at = now
    if report.status != ReportStatus.waiting_user:
        report.resolved_at = now
    session.add(report)
    if outcome == ReportOutcome.deleted and session.get(Card, report.card_id):
        delete_card(session, report.card_id)  # commits the report too
    session.commit()
    return _report_read(session, report)


# --- Feedback (spec 025) ----------------------------------------------------------------------

FEEDBACK_MAX = 2000
FeedbackFilter = Literal["all"] | FeedbackStatus


def _save_feedback(session: Session, feedback: Feedback) -> FeedbackRead:
    session.add(feedback)
    session.commit()
    session.refresh(feedback)  # commit expires the row; model_dump doesn't reload it
    return FeedbackRead(**feedback.model_dump())


def send_feedback(
    session: Session,
    message: str,
    kind: FeedbackKind = FeedbackKind.other,
    now: datetime | None = None,
) -> FeedbackRead:
    """Stores feedback for the developer (trimmed message, 1-2000 chars). Touches nothing else."""
    message = message.strip()
    if not message:
        raise InvalidFeedback("`message` is required: what went wrong, or what's missing.")
    if len(message) > FEEDBACK_MAX:
        raise InvalidFeedback(f"`message` is at most {FEEDBACK_MAX} characters.")
    feedback = Feedback(kind=kind, message=message, created_at=now or utcnow())
    return _save_feedback(session, feedback)


def list_feedback(session: Session, status: FeedbackFilter = "open") -> list[FeedbackRead]:
    """Oldest first."""
    statement = select(Feedback).order_by(col(Feedback.created_at))
    if status != "all":
        statement = statement.where(Feedback.status == status)
    return [FeedbackRead(**feedback.model_dump()) for feedback in session.exec(statement)]


def close_feedback(
    session: Session, feedback_id: UUID, note: str | None = None, now: datetime | None = None
) -> FeedbackRead:
    """Marks open feedback as done; a blank `note` is stored as no resolution."""
    feedback = session.get(Feedback, feedback_id)
    if feedback is None:
        raise FeedbackNotFound(feedback_id)
    if feedback.status == FeedbackStatus.done:
        raise InvalidFeedback(f"Feedback {feedback_id} is already done.")
    feedback.status = FeedbackStatus.done
    feedback.resolution = (note or "").strip() or None
    feedback.closed_at = now or utcnow()
    return _save_feedback(session, feedback)


def _local_midnight(day: date, tz: tzinfo) -> datetime:
    """Start of `day` in `tz`, as UTC (a local day is 23 or 25 hours long across DST)."""
    return datetime.combine(day, time(), tzinfo=tz).astimezone(UTC)


def _history(studied: set[date], today: date) -> tuple[date, str]:
    """(first day, one letter per local day from it to `today`), spec 024 decision 3.

    `s` studied, `f` frozen, `m` missed, `p` today not yet studied. Walking chronologically, a
    missed day is frozen when the day before is studied, no frozen day lies in the 6 days before
    it, and the day after is studied or is today (so a missed yesterday is frozen provisionally)."""
    start = min(studied, default=today)
    letters, last_freeze, day = [], None, start
    while day < today:
        if day in studied:
            letters.append("s")
        elif (
            day - _DAY in studied
            and (last_freeze is None or day - last_freeze > 6 * _DAY)
            and (day + _DAY in studied or day + _DAY == today)
        ):
            letters.append("f")
            last_freeze = day
        else:
            letters.append("m")
        day += _DAY
    letters.append("s" if today in studied else "p")
    return start, "".join(letters)


def _streak(history: str, start: date) -> tuple[int, date | None]:
    """(days in the current run, its first day): the trailing studied/frozen days, ending today,
    or yesterday while today is pending."""
    run = history.removesuffix("p")
    streak = len(run) - len(run.rstrip("sf"))
    return streak, start + (len(run) - streak) * _DAY if streak else None
