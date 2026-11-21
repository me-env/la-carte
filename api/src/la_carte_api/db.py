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

    SQLModel.metadata.create_all(engine)
    _migrate(engine)
    return engine


def _migrate(engine: Engine) -> None:
    """Schema changes on existing tables, in spec order. Idempotent: each step checks the schema
    with PRAGMA first.

    - Spec 012: `reviewlog.card_id` lost its `ON DELETE CASCADE` foreign key so review history
      survives deleting a card. SQLite can't drop a constraint: the table is rebuilt.
    - Spec 013: `reviewlog.confidence` (nullable REAL) is added; existing rows read NULL.
    """
    raw = engine.raw_connection()
    db = raw.driver_connection  # sqlite3: explicit BEGIN/COMMIT, so DDL is transactional too
    isolation_level, db.isolation_level = db.isolation_level, None
    try:
        _rebuild_if(
            db, engine, "012", lambda: _has_foreign_key(db, "reviewlog"), _rebuild_reviewlog
        )
        if "confidence" not in _columns(db, "reviewlog"):
            db.execute("ALTER TABLE reviewlog ADD COLUMN confidence FLOAT")
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
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
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


def sessions(engine: Engine) -> Iterator[Session]:
    with Session(engine) as session:
        yield session
