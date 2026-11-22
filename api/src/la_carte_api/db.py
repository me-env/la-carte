import json
import logging
from collections.abc import Iterator
from datetime import UTC, datetime

from sqlalchemy import DateTime, MetaData, TypeDecorator, event
from sqlalchemy.engine import Engine
from sqlalchemy.schema import CreateIndex, CreateTable
from sqlmodel import Session, SQLModel, create_engine
from sqlmodel.pool import StaticPool

log = logging.getLogger(__name__)


class UTCDateTime(TypeDecorator[datetime]):
    """Stores datetimes as naive UTC (SQLite has no time zones) and hands them back UTC-aware."""

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        return value.astimezone(UTC).replace(tzinfo=None) if value else None

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        return value.replace(tzinfo=UTC) if value else None


def make_engine(database_url: str) -> Engine:
    if database_url == "sqlite://":  # in-memory, used by tests: share one connection
        engine = create_engine(
            database_url, connect_args={"check_same_thread": False}, poolclass=StaticPool
        )
    else:
        engine = create_engine(database_url, connect_args={"check_same_thread": False})

    @event.listens_for(engine, "connect")
    def _enable_foreign_keys(connection, _record) -> None:
        connection.execute("PRAGMA foreign_keys=ON")

    from la_carte_api import models  # noqa: F401  (registers the tables)

    _migrate(engine)  # first, so a backup is an exact copy of the file as it was
    SQLModel.metadata.create_all(engine)  # new tables (every table on a fresh database)
    return engine


def _migrate(engine: Engine) -> None:
    """Schema changes on existing tables, in spec order, before `create_all`. Idempotent: each
    step checks the schema with PRAGMA first (a missing table = a fresh database: skipped).

    - Spec 012: `reviewlog.card_id` lost its `ON DELETE CASCADE` foreign key so review history
      survives deleting a card. SQLite can't drop a constraint: the table is rebuilt.
    - Spec 013: `reviewlog.confidence` (nullable REAL) is added; existing rows read NULL.
    - Spec 014: cards become directions over notes: each card gets a `basic` note with the same
      id holding its front/back, and `card` is rebuilt without front/back.
    - Spec 014a amendment: person `role` and `context` fold into `description` (data only).
    - Spec 015: the `report` table is created (with a backup, like the rebuilds).
    - Spec 021: the `settings` table is created, without a row (a missing row = the defaults).
    """
    raw = engine.raw_connection()
    db = raw.driver_connection  # sqlite3: explicit BEGIN/COMMIT, so DDL is transactional too
    isolation_level, db.isolation_level = db.isolation_level, None
    try:
        _rebuild_if(
            db, engine, "012", lambda: _has_foreign_key(db, "reviewlog"), _rebuild_reviewlog
        )
        if (columns := _columns(db, "reviewlog")) and "confidence" not in columns:
            db.execute("ALTER TABLE reviewlog ADD COLUMN confidence FLOAT")
        _rebuild_if(db, engine, "014", lambda: "front" in _columns(db, "card"), _cards_to_notes)
        _rebuild_if(db, engine, "014a", lambda: _has_person_roles(db), _fold_person_roles)
        _rebuild_if(
            db, engine, "015", lambda: bool(_columns(db, "card")) and not _columns(db, "report"),
            _create_reports,
        )  # fmt: skip
        _rebuild_if(
            db, engine, "021", lambda: bool(_columns(db, "card")) and not _columns(db, "settings"),
            _create_settings,
        )  # fmt: skip
    finally:
        db.execute("PRAGMA foreign_keys=ON")
        db.isolation_level = isolation_level
        raw.close()


def _rebuild_if(db, engine: Engine, spec: str, needed, rebuild) -> None:
    """Runs `rebuild(db, dialect)` if `needed()`, in one transaction: a failure rolls back and
    leaves the old tables intact. File databases are first copied to
    `<db>.pre-<spec>-<UTC timestamp>.bak`."""
    if not needed():
        return
    if (path := engine.url.database) and path != ":memory:":
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%fZ")  # unique across quick restarts
        db.execute("VACUUM INTO ?", (f"{path}.pre-{spec}-{stamp}.bak",))
    db.execute("PRAGMA foreign_keys=OFF")  # no-op inside a transaction: set before BEGIN
    db.execute("BEGIN IMMEDIATE")
    try:
        if needed():  # re-check under the write lock
            rebuild(db, engine.dialect)
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise


def _has_foreign_key(db, table: str) -> bool:
    return bool(db.execute(f"PRAGMA foreign_key_list({table})").fetchall())


def _columns(db, table: str) -> set[str]:
    return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}


def _rebuild_reviewlog(db, dialect) -> None:
    """Recreate `reviewlog` from the model's DDL (no foreign key). Rows with a NULL `card_id`
    (orphans, unusable for stats) can't go into the NOT NULL column: they are skipped, logged,
    and stay in the backup."""
    from la_carte_api.models import ReviewLog

    table = ReviewLog.__table__
    new = table.to_metadata(MetaData(), name=f"{table.name}_new")
    old_columns = _columns(db, table.name)  # a pre-013 table has no `confidence`
    columns = ", ".join(c.name for c in table.columns if c.name in old_columns)
    db.execute(str(CreateTable(new).compile(dialect=dialect)))
    db.execute(
        f"INSERT INTO {new.name} ({columns}) SELECT {columns} FROM {table.name} "
        "WHERE card_id IS NOT NULL"
    )
    [(skipped,)] = db.execute(f"SELECT count(*) FROM {table.name} WHERE card_id IS NULL")
    db.execute(f"DROP TABLE {table.name}")
    db.execute(f"ALTER TABLE {new.name} RENAME TO {table.name}")
    for index in table.indexes:
        db.execute(str(CreateIndex(index).compile(dialect=dialect)))
    if skipped:
        log.warning("reviewlog rebuild skipped %d review(s) with no card_id", skipped)


def _cards_to_notes(db, dialect) -> None:
    """Spec 014: every card becomes a `basic` note reusing the card's id (deterministic, no
    mapping table) with fields {front, back}, and the card becomes its `front -> back` direction.
    Card ids, FSRS state and review logs are untouched."""
    from la_carte_api.models import Card, Note

    metadata = MetaData()  # holds `note` too, so card_new's foreign key compiles
    note = Note.__table__.to_metadata(metadata)
    card = Card.__table__
    new = card.to_metadata(metadata, name=f"{card.name}_new")
    db.execute(str(CreateTable(note).compile(dialect=dialect)))
    db.execute(
        "INSERT INTO note (id, type, fields, created_at, updated_at) "
        "SELECT id, 'basic', json_object('front', front, 'back', back), created_at, updated_at "
        "FROM card"
    )
    old_columns = _columns(db, card.name)
    kept = ", ".join(c.name for c in card.columns if c.name in old_columns)  # id, dates, FSRS
    db.execute(str(CreateTable(new).compile(dialect=dialect)))
    db.execute(
        f"INSERT INTO {new.name} ({kept}, note_id, prompt, answer) "
        f"SELECT {kept}, id, '[\"front\"]', '[\"back\"]' FROM {card.name}"
    )
    db.execute(f"DROP TABLE {card.name}")
    db.execute(f"ALTER TABLE {new.name} RENAME TO {card.name}")
    for index in card.indexes:
        db.execute(str(CreateIndex(index).compile(dialect=dialect)))
    if db.execute("PRAGMA foreign_key_check").fetchall():  # never expected: abort, roll back
        raise RuntimeError("cards-to-notes migration left a card without its note")


_PERSON_ROLES = (
    "SELECT id, fields FROM note WHERE type = 'person' AND "
    "(json_type(fields, '$.role') IS NOT NULL OR json_type(fields, '$.context') IS NOT NULL)"
)


def _has_person_roles(db) -> bool:
    return bool(_columns(db, "note")) and bool(db.execute(_PERSON_ROLES).fetchone())


def _fold_person_roles(db, dialect) -> None:
    """Person notes: `description` = "role — context" (the set ones, after any description), and
    each card becomes `prompt -> every other field`, its prompt mapped role/context ->
    description. A card that duplicates a sibling's direction is deleted (its reviews stay)."""
    fields_order = ("photo", "name", "description")
    for note_id, raw in db.execute(_PERSON_ROLES).fetchall():
        fields = json.loads(raw)
        parts = [fields.pop(f, "").strip() for f in ("description", "role", "context")]
        if description := " — ".join(part for part in parts if part):
            fields["description"] = description
        db.execute("UPDATE note SET fields = ? WHERE id = ?", (json.dumps(fields), note_id))
        seen: set[str] = set()
        cards = db.execute(
            "SELECT id, prompt FROM card WHERE note_id = ? ORDER BY created_at", (note_id,)
        ).fetchall()
        for card_id, prompt in cards:
            mapped = [f if f in fields_order else "description" for f in json.loads(prompt)]
            first = min(mapped, key=fields_order.index) if mapped else "name"
            if first in seen:
                db.execute("DELETE FROM card WHERE id = ?", (card_id,))
                continue
            seen.add(first)
            answer = [f for f in fields_order if f != first]
            db.execute(
                "UPDATE card SET prompt = ?, answer = ? WHERE id = ?",
                (json.dumps([first]), json.dumps(answer), card_id),
            )


def _create_reports(db, dialect) -> None:
    from la_carte_api.models import Report

    table = Report.__table__
    db.execute(str(CreateTable(table).compile(dialect=dialect)))
    for index in table.indexes:
        db.execute(str(CreateIndex(index).compile(dialect=dialect)))


def _create_settings(db, dialect) -> None:
    from la_carte_api.models import Settings

    db.execute(str(CreateTable(Settings.__table__).compile(dialect=dialect)))


def sessions(engine: Engine) -> Iterator[Session]:
    with Session(engine) as session:
        yield session
