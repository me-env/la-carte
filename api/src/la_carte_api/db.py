import json
import logging
import os
import shutil
from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import uuid4

import sqlcipher3.dbapi2 as sqlcipher
from sqlalchemy import DateTime, MetaData, Table, TypeDecorator, event, inspect
from sqlalchemy.engine import Engine, make_url
from sqlalchemy.schema import CreateIndex, CreateTable
from sqlmodel import Session, SQLModel, create_engine
from sqlmodel.pool import StaticPool

from la_carte_api.config import HEX_KEY

log = logging.getLogger(__name__)


class UTCDateTime(TypeDecorator[datetime]):
    """Stores datetimes as naive UTC (SQLite has no time zones) and hands them back UTC-aware."""

    impl = DateTime
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        return value.astimezone(UTC).replace(tzinfo=None) if value else None

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        return value.replace(tzinfo=UTC) if value else None


NEEDS_OWNER = (
    "This deck has data: set LA_CARTE_OWNER_EMAIL to the Google or Apple email of its owner"
)


WRONG_KEY = "LA_CARTE_DB_KEY doesn't open this database"
NEEDS_KEY = "This database is encrypted: set LA_CARTE_DB_KEY"
REKEYED = "rekeyed: set LA_CARTE_DB_KEY to the new value and remove LA_CARTE_DB_KEY_NEW"
PLAINTEXT_HEADER = b"SQLite format 3\0"


class MigrationRefused(RuntimeError):
    """The database can't be migrated with this configuration; nothing was changed."""


def make_engine(
    database_url: str,
    owner_email: str | None = None,
    key: str | None = None,
    new_key: str | None = None,
) -> Engine:
    """The engine, after the startup migrations (see `open_database`)."""
    engine, _ = open_database(database_url, owner_email, key, new_key)
    return engine


def open_database(
    database_url: str,
    owner_email: str | None = None,
    key: str | None = None,
    new_key: str | None = None,
) -> tuple[Engine, bool]:
    """The engine after the startup migrations, and whether this start created the `user` table
    (migration 030 ran, or the database is new). `owner_email` (`LA_CARTE_OWNER_EMAIL`) owns the
    data of a pre-030 database (migration 030); without it such a database is refused.

    `key` (`LA_CARTE_DB_KEY`, 64 hex) opens a database file through SQLCipher (spec 032a); a
    plaintext file is encrypted first, and `new_key` rekeys it (see `_settle_key`). Without a key,
    and for the in-memory database, it is plain SQLite."""
    if database_url == "sqlite://":  # in-memory, used by tests: share one connection
        key = None
        engine = create_engine(
            database_url, connect_args={"check_same_thread": False}, poolclass=StaticPool
        )
    else:
        key = _settle_key(make_url(database_url).database, key, new_key)
        module = {"module": sqlcipher} if key else {}
        engine = create_engine(database_url, connect_args={"check_same_thread": False}, **module)

    @event.listens_for(engine, "connect")
    def _on_connect(connection, _record) -> None:
        if key:
            connection.execute(_key_pragma("key", key))  # first, before anything reads the file
        connection.execute("PRAGMA foreign_keys=ON")

    from la_carte_api import models  # noqa: F401  (registers the tables)

    first_start = not inspect(engine).has_table("user")
    _migrate(engine, owner_email)  # first, so a backup is an exact copy of the file as it was
    SQLModel.metadata.create_all(engine)  # new tables (every table on a fresh database)
    return engine, first_start


def _settle_key(path: str, key: str | None, new_key: str | None) -> str | None:
    """The key the engine opens `path` with, after encrypting a plaintext file with `key` and
    rekeying it to `new_key` (spec 032a). Refuses (`MigrationRefused`, file untouched) an
    encrypted file without a key, or that neither key opens."""
    if not key:
        if _size(path) and not _is_plaintext(path):
            raise MigrationRefused(NEEDS_KEY)
        return None
    if _is_plaintext(path):
        _encrypt(path, key)
    if not _size(path):  # a new database: created with the newest key
        if new_key:
            log.warning(REKEYED)
        return new_key or key
    if _opens(path, key):
        if not new_key:
            return key
        _rekey(path, key, new_key)
    elif not (new_key and _opens(path, new_key)):  # new_key: a restart before the env swap
        raise MigrationRefused(WRONG_KEY)
    log.warning(REKEYED)
    return new_key


def _key_pragma(pragma: str, key: str) -> str:
    """`PRAGMA key` / `PRAGMA rekey` with a raw 256-bit key (no passphrase derivation)."""
    if not HEX_KEY.fullmatch(key):
        raise ValueError("a database key is 64 hex characters")
    return f"PRAGMA {pragma} = \"x'{key}'\""


def _size(path: str) -> int:
    return os.path.getsize(path) if os.path.exists(path) else 0


def _is_plaintext(path: str) -> bool:
    if not _size(path):
        return False
    with open(path, "rb") as file:
        return file.read(len(PLAINTEXT_HEADER)) == PLAINTEXT_HEADER


def _opens(path: str, key: str) -> bool:
    db = sqlcipher.connect(path)
    try:
        db.execute(_key_pragma("key", key))
        db.execute("SELECT count(*) FROM sqlite_master").fetchone()
        return True
    except sqlcipher.DatabaseError:
        return False
    finally:
        db.close()


def _rekey(path: str, key: str, new_key: str) -> None:
    db = sqlcipher.connect(path)
    try:
        db.execute(_key_pragma("key", key))
        db.execute(_key_pragma("rekey", new_key))
    finally:
        db.close()


def _encrypt(path: str, key: str) -> None:
    """Encrypts the plaintext file `path` with `key` (spec 032a decision 3): exported to
    `<db>.encrypting`, checked (same rows in every table), the original copied to
    `<db>.pre-032-<timestamp>.bak`, then `.encrypting` atomically replaces it. A failure or a
    crash at any step leaves the plaintext file in place (the next start tries again)."""
    encrypting = f"{path}.encrypting"
    if os.path.exists(encrypting):  # left by an interrupted attempt
        os.remove(encrypting)
    plain = sqlcipher.connect(path)
    try:
        plain.execute("ATTACH DATABASE ? AS enc KEY ?", (encrypting, f"x'{key}'"))
        plain.execute("SELECT sqlcipher_export('enc')").fetchall()
        plain.execute("DETACH DATABASE enc")
        expected = _row_counts(plain)
    finally:
        plain.close()
    encrypted = sqlcipher.connect(encrypting)
    try:
        encrypted.execute(_key_pragma("key", key))
        same = _row_counts(encrypted) == expected
    finally:
        encrypted.close()
    if not same:
        os.remove(encrypting)
        raise RuntimeError("encrypting the database lost rows: the plaintext file is kept")
    backup = f"{path}.pre-032-{_stamp()}.bak"
    shutil.copy2(path, backup)
    os.replace(encrypting, path)
    log.warning(
        "database encrypted; the plaintext copy %s stays until you delete it",
        os.path.basename(backup),
    )


def _row_counts(db) -> dict[str, int]:
    tables = db.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    return {name: db.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0] for (name,) in tables}


def _stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%fZ")  # unique across quick restarts


def _migrate(engine: Engine, owner_email: str | None = None) -> None:
    """Schema changes on existing tables, in spec order, before `create_all`. Idempotent: each
    step checks the schema with PRAGMA first (a missing table = a fresh database: skipped).

    - Spec 012: `reviewlog.card_id` lost its `ON DELETE CASCADE` foreign key so review history
      survives deleting a card. SQLite can't drop a constraint: the table is rebuilt.
    - Spec 013: `reviewlog.confidence` (nullable REAL) is added; existing rows read NULL.
    - Spec 014: cards become directions over notes: each card gets a `basic` note with the same
      id holding its front/back, and `card` is rebuilt without front/back.
    - Spec 014a amendment: person `role` and `context` fold into `description` (data only).
    - Spec 015: the `report` table is created (with a backup, like the rebuilds).
    - Spec 021: the `settings` table is created, without a row (a missing row = the defaults);
      `reviewlog.stability_before` / `last_review_before` (nullable) are added; old rows read NULL.
    - Spec 030a: every owned table gets `user_id`; existing rows go to a new `user` row for
      `owner_email` (refused, untouched, when there is data and no owner); `settings` is rebuilt
      keyed by `user_id`. Rebuilds before it that copy rows (012, 014) build their tables
      without `user_id` (`_pre_030`); 015 and 021 create empty current tables.
    """
    raw = engine.raw_connection()
    db = raw.driver_connection  # sqlite3: explicit BEGIN/COMMIT, so DDL is transactional too
    isolation_level, db.isolation_level = db.isolation_level, None
    try:
        _rebuild_if(
            db, engine, "012", lambda: _has_foreign_key(db, "reviewlog"), _rebuild_reviewlog
        )
        _add_columns(
            db, "reviewlog",
            {"confidence": "FLOAT", "stability_before": "FLOAT", "last_review_before": "DATETIME"},
        )  # fmt: skip
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
        if _needs_owners(db) and not owner_email and _has_owned_rows(db):
            raise MigrationRefused(NEEDS_OWNER)  # before the backup: nothing changes
        _rebuild_if(
            db, engine, "030", lambda: _needs_owners(db),
            lambda db, dialect: _add_owners(db, dialect, owner_email),
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
        # Through SQLCipher, the copy is encrypted with the same key (spec 032a decision 5).
        db.execute("VACUUM INTO ?", (f"{path}.pre-{spec}-{_stamp()}.bak",))
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


def _add_columns(db, table: str, columns: dict[str, str]) -> None:
    """`ALTER TABLE … ADD COLUMN` for each missing nullable column (name -> SQL type)."""
    if existing := _columns(db, table):
        for name, sql_type in columns.items():
            if name not in existing:
                db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")


def _columns(db, table: str) -> set[str]:
    return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}


def _rebuild_reviewlog(db, dialect) -> None:
    """Recreate `reviewlog` from the model's DDL (no foreign key). Rows with a NULL `card_id`
    (orphans, unusable for stats) can't go into the NOT NULL column: they are skipped, logged,
    and stay in the backup."""
    from la_carte_api.models import ReviewLog

    table = _pre_030(ReviewLog.__table__, MetaData())
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
    note = _pre_030(Note.__table__, metadata)
    card = _pre_030(Card.__table__, MetaData())
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

    table = Report.__table__  # empty: migration 030 rebuilds it later if needed
    db.execute(str(CreateTable(table).compile(dialect=dialect)))
    for index in table.indexes:
        db.execute(str(CreateIndex(index).compile(dialect=dialect)))


def _create_settings(db, dialect) -> None:
    from la_carte_api.models import Settings

    db.execute(str(CreateTable(Settings.__table__).compile(dialect=dialect)))


def _pre_030(table: Table, metadata: MetaData) -> Table:
    """`table` as it was before spec 030 (no `user_id`), for the migration steps before it."""
    columns = [column._copy() for column in table.columns if column.name != "user_id"]
    return Table(table.name, metadata, *columns)


def _needs_owners(db) -> bool:
    return bool(_columns(db, "note")) and "user_id" not in _columns(db, "note")


def _has_owned_rows(db) -> bool:
    from la_carte_api.models import OWNED

    return any(
        _columns(db, table) and db.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone()
        for table in (model.__table__.name for model in OWNED)
    )


def _add_owners(db, dialect, owner_email: str | None) -> None:
    """Spec 030a: every owned table rebuilt from its model with `user_id` = the owner, a new
    `user` row (only when there is data). Ids and every other column are copied as they are."""
    from la_carte_api import models

    db.execute(str(CreateTable(models.User.__table__, if_not_exists=True).compile(dialect=dialect)))
    owner = None
    if _has_owned_rows(db):
        owner = uuid4().hex  # how `Uuid` is stored in SQLite
        stamp = datetime.now(UTC).strftime("%Y-%m-%d %H:%M:%S.%f")
        db.execute(
            'INSERT INTO "user" (id, email, created_at) VALUES (?, ?, ?)',
            (owner, owner_email, stamp),
        )
    metadata = MetaData()  # holds `note`, so card_new's foreign key compiles
    models.Note.__table__.to_metadata(metadata)
    for model in models.OWNED:
        if model is models.Settings:
            continue  # keyed by `user_id`: rebuilt below
        table = model.__table__
        if not (old_columns := _columns(db, table.name)):
            continue  # created later by create_all
        new = table.to_metadata(metadata, name=f"{table.name}_new")
        kept = ", ".join(c.name for c in table.columns if c.name in old_columns - {"user_id"})
        db.execute(str(CreateTable(new).compile(dialect=dialect)))
        db.execute(
            f"INSERT INTO {new.name} (user_id, {kept}) SELECT ?, {kept} FROM {table.name}",
            (owner,),
        )
        _replace(db, dialect, table, new.name)
    rows = []
    if _columns(db, "settings"):
        rows = db.execute("SELECT new_cards_per_day FROM settings LIMIT 1").fetchall()
        db.execute("DROP TABLE settings")
    db.execute(str(CreateTable(models.Settings.__table__).compile(dialect=dialect)))
    if rows and owner:
        db.execute(
            "INSERT INTO settings (user_id, new_cards_per_day) VALUES (?, ?)", (owner, rows[0][0])
        )
    if db.execute("PRAGMA foreign_key_check").fetchall():  # never expected: abort, roll back
        raise RuntimeError("migration 030 left a card without its note")


def _replace(db, dialect, table: Table, new_name: str) -> None:
    """Drops `table`, renames `new_name` to it and creates the model's indexes."""
    db.execute(f"DROP TABLE {table.name}")
    db.execute(f"ALTER TABLE {new_name} RENAME TO {table.name}")
    for index in table.indexes:
        db.execute(str(CreateIndex(index).compile(dialect=dialect)))


def sessions(engine: Engine) -> Iterator[Session]:
    with Session(engine) as session:
        yield session
