from collections.abc import Iterator
from datetime import UTC, datetime

from sqlalchemy import DateTime, TypeDecorator, event
from sqlalchemy.engine import Engine
from sqlmodel import Session, SQLModel, create_engine
from sqlmodel.pool import StaticPool


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
    return engine


def sessions(engine: Engine) -> Iterator[Session]:
    with Session(engine) as session:
        yield session
