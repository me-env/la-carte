"""Spec 032a: the whole database file through SQLCipher with `LA_CARTE_DB_KEY`."""

import logging
import sqlite3
from pathlib import Path
from uuid import uuid4

import pytest
import sqlcipher3.dbapi2 as sqlcipher
from conftest import add_user, bearer, token_for
from fastapi.testclient import TestClient
from sqlmodel import Session, select
from test_migration import CARD, OLD_SCHEMA

from la_carte_api import auth, db, deck
from la_carte_api.app import create_app
from la_carte_api.config import DB_KEY_HELP, Settings
from la_carte_api.db import (
    NEEDS_KEY,
    REKEY_FAILED,
    REKEYED,
    WRONG_KEY,
    MigrationRefused,
    make_engine,
)
from la_carte_api.models import (
    ApiToken,
    FeedbackKind,
    Note,
    NoteCreate,
    ReportCreate,
    ReportReason,
    TokenKind,
    TokenScope,
)

K1 = "1a2b3c4d" * 8
K2 = "9f8e7d6c" * 8
MCP_HEADERS = {"Accept": "application/json, text/event-stream"}
EMAILS = ("alice-marker@example.com", "bob-marker@example.com")
MARKERS = ("front-marker", "back-marker", "report-marker", "feedback-marker", "activity-marker")


@pytest.fixture(autouse=True)
def no_key_in_logs(caplog):  # A6: every log line of these tests, at every level
    caplog.set_level(logging.DEBUG)
    yield
    for key in (K1, K2):
        assert key not in caplog.text and key.upper() not in caplog.text


def _settings(path: Path, **settings) -> Settings:
    return Settings(database_url=f"sqlite:///{path}", _env_file=None, **settings)


def _start(path: Path, **settings) -> None:
    """One server start (startup migrations included), then shut down."""
    create_app(_settings(path, **settings)).state.engine.dispose()


def _opens_with(path: Path, key: str | None) -> bool:
    connection = sqlcipher.connect(path)
    try:
        if key:
            connection.execute(f"PRAGMA key = \"x'{key}'\"")
        connection.execute("SELECT count(*) FROM sqlite_master").fetchone()
        return True
    except sqlcipher.DatabaseError:
        return False
    finally:
        connection.close()


def _rows(path: Path, key: str | None = None) -> dict[str, list]:
    """Every row of every table."""
    connection = sqlcipher.connect(path)
    try:
        if key:
            connection.execute(f"PRAGMA key = \"x'{key}'\"")
        tables = connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        ).fetchall()
        return {
            name: sorted(connection.execute(f'SELECT * FROM "{name}"').fetchall(), key=repr)
            for (name,) in tables
        }
    finally:
        connection.close()


def _seed(path: Path, key: str | None = None) -> list[str]:
    """Users, notes, a report, feedback, activity and tokens; returns tokens and hashes."""
    engine = make_engine(f"sqlite:///{path}", key=key)
    alice = add_user(engine, EMAILS[0])
    add_user(engine, EMAILS[1])
    tokens = [token_for(engine, alice)]
    with Session(engine) as session:
        tokens.append(auth.mint(session, alice, TokenKind.access, TokenScope.deck))
        note = NoteCreate(type="basic", fields={"front": MARKERS[0], "back": MARKERS[1]})
        card_id = deck.add_notes(session, alice, [note]).added[0].cards[0].id
        report = ReportCreate(reason=ReportReason.other, comment=MARKERS[2])
        deck.report_card(session, alice, card_id, report)
        deck.send_feedback(session, alice, MARKERS[3], FeedbackKind.bug)
        event = {
            "id": str(uuid4()),
            "kind": "card_shown",
            "at": "2026-11-28T10:00:00Z",
            "tz": "Europe/Paris",
            "session": str(uuid4()),
            "app_version": "1.0",
            "build": "1",
            "os": "iOS 26",
            "data": {"note": MARKERS[4]},
        }
        assert deck.ingest_activity(session, alice, [event]).stored == 1
        hashes = [token.hash for token in session.exec(select(ApiToken)).all()]
    engine.dispose()
    return tokens + hashes


def test_a_new_database_is_encrypted_and_serves_rest_and_mcp(tmp_path):  # A1
    path = tmp_path / "deck.db"
    with TestClient(create_app(_settings(path, db_key=K1))) as client:
        engine = client.app.state.engine
        token = token_for(engine, add_user(engine, EMAILS[0]))
        note = {"type": "basic", "fields": {"front": "chat", "back": "cat"}}
        assert client.post("/notes", json=note, headers=bearer(token)).is_success
        assert client.get("/notes", headers=bearer(token)).json()[0]["fields"]["front"] == "chat"
        body = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        listed = client.post("/mcp", json=body, headers=MCP_HEADERS | bearer(token))
        assert "add_notes" in {tool["name"] for tool in listed.json()["result"]["tools"]}
        engine.dispose()
    assert not path.read_bytes().startswith(b"SQLite format 3")
    with pytest.raises(sqlite3.DatabaseError, match="not a database"):
        sqlite3.connect(path).execute("SELECT * FROM sqlite_master").fetchall()
    assert _opens_with(path, K1)


def test_a_plaintext_database_is_encrypted_once_with_a_backup(tmp_path, caplog):  # A2
    path = tmp_path / "deck.db"
    _seed(path)
    plaintext, rows = path.read_bytes(), _rows(path)
    assert plaintext.startswith(b"SQLite format 3\0")

    _start(path, db_key=K1)
    assert not path.read_bytes().startswith(b"SQLite format 3")
    assert _rows(path, K1) == rows  # every table, every row
    [backup] = tmp_path.glob("deck.db.pre-032-*.bak")
    assert backup.read_bytes() == plaintext
    assert f"the plaintext copy {backup.name} stays until you delete it" in caplog.text
    assert not (tmp_path / "deck.db.encrypting").exists()

    encrypted = path.read_bytes()
    _start(path, db_key=K1)  # idempotent
    assert path.read_bytes() == encrypted
    assert len(list(tmp_path.glob("deck.db.pre-032-*.bak"))) == 1


def test_a_failed_encryption_keeps_the_plaintext_file(tmp_path, monkeypatch):  # A2, safety
    path = tmp_path / "deck.db"
    _seed(path)
    plaintext = path.read_bytes()
    (tmp_path / "deck.db.encrypting").write_bytes(b"left by a crash")
    counts = iter([{"note": 1}, {"note": 0}])  # the export "lost" a row
    monkeypatch.setattr(db, "_row_counts", lambda _db: next(counts))

    with pytest.raises(RuntimeError, match="lost rows"):
        _start(path, db_key=K1)
    assert path.read_bytes() == plaintext
    assert sorted(p.name for p in tmp_path.iterdir()) == ["deck.db"]

    monkeypatch.undo()
    for leftover in ("deck.db.encrypting-journal", "deck.db.encrypting-wal"):
        (tmp_path / leftover).write_bytes(b"left by a crash")
    _start(path, db_key=K1)  # the next start tries again, over the stale `.encrypting*`
    assert _opens_with(path, K1)
    assert not list(tmp_path.glob("deck.db.encrypting*"))


def test_a_wrong_key_refuses_to_start_and_leaves_the_file(tmp_path):  # A3
    path = tmp_path / "deck.db"
    _seed(path, K1)
    encrypted = path.read_bytes()
    with pytest.raises(MigrationRefused, match=WRONG_KEY):
        _start(path, db_key=K2)
    with pytest.raises(MigrationRefused, match=NEEDS_KEY):
        _start(path)  # no key at all
    assert path.read_bytes() == encrypted
    assert sorted(p.name for p in tmp_path.iterdir()) == ["deck.db"]


@pytest.mark.parametrize(
    "settings",
    [
        {"public_url": "https://example.com"},
        {"public_url": "https://example.com", "db_key": ""},  # Compose's unset variable
        {"public_url": "https://example.com", "db_key": "abc"},
        {"public_url": "https://example.com", "db_key": "zz" * 32},
        {"public_url": "carte.example.com"},  # no scheme: no parseable host, still production
        {"db_key": K1[:-1]},  # malformed even off production
        {"db_key": K1, "db_key_new": "abc"},
    ],
)
def test_production_needs_a_well_formed_key(tmp_path, settings):  # A4
    with pytest.raises(RuntimeError, match=DB_KEY_HELP):
        _start(tmp_path / "deck.db", **settings)
    assert not list(tmp_path.iterdir())  # refused before touching the database


@pytest.mark.parametrize(
    "public_url", [None, "http://127.0.0.1:8000", "http://localhost:8000", "http://[::1]:8000"]
)
def test_local_servers_start_on_plain_sqlite_without_a_key(tmp_path, public_url):  # A4
    path = tmp_path / "deck.db"
    _start(path, public_url=public_url)
    assert path.read_bytes().startswith(b"SQLite format 3\0")


def test_in_memory_databases_need_no_key_in_production():  # unit tests' `sqlite://`
    settings = Settings(database_url="sqlite://", public_url="https://example.com", _env_file=None)
    create_app(settings).state.engine.dispose()


def test_rekey_moves_the_file_to_the_new_key(tmp_path, caplog):  # A5
    path = tmp_path / "deck.db"
    _seed(path, K1)
    rows = _rows(path, K1)

    _start(path, db_key=K1, db_key_new=K2)
    assert _opens_with(path, K2) and not _opens_with(path, K1)
    assert REKEYED in caplog.text

    caplog.clear()
    _start(path, db_key=K1, db_key_new=K2)  # restarted before the env was swapped
    assert REKEYED in caplog.text
    _start(path, db_key=K2)
    assert _rows(path, K2) == rows

    with pytest.raises(RuntimeError, match="set LA_CARTE_DB_KEY to the current key"):
        _start(path, db_key_new=K2)


def test_a_rekey_that_did_not_take_refuses_to_start(tmp_path, monkeypatch, caplog):  # A5
    path = tmp_path / "deck.db"
    _seed(path, K1)
    monkeypatch.setattr(db, "_rekey", lambda *_: None)  # PRAGMA rekey silently did nothing
    with pytest.raises(MigrationRefused, match=REKEY_FAILED):
        _start(path, db_key=K1, db_key_new=K2)
    assert REKEYED not in caplog.text
    assert _opens_with(path, K1)


def test_the_key_pragma_runs_first_on_the_first_connection(tmp_path, monkeypatch):  # A1
    statements: list[list[str]] = []  # per connection, in order
    connect = sqlcipher.connect

    def traced(*args, **kwargs):
        connection = connect(*args, **kwargs)
        statements.append([])
        connection.set_trace_callback(statements[-1].append)
        return connection

    monkeypatch.setattr(sqlcipher, "connect", traced)
    make_engine(f"sqlite:///{tmp_path / 'deck.db'}", key=K1).dispose()
    assert statements[0][0].startswith("PRAGMA key"), statements[0][:3]


def test_only_a_wrong_key_reads_as_a_wrong_key(tmp_path, monkeypatch):  # A3
    path = tmp_path / "deck.db"
    _seed(path, K1)

    class Locked:
        def execute(self, sql):
            if not sql.startswith("PRAGMA key"):
                raise sqlcipher.OperationalError("database is locked")

        def close(self):
            pass

    monkeypatch.setattr(db.sqlcipher, "connect", lambda _path: Locked())
    with pytest.raises(sqlcipher.OperationalError, match="database is locked"):
        db._opens(str(path), K1)
    monkeypatch.undo()
    assert db._opens(str(path), K1) and not db._opens(str(path), K2)


def test_a_plaintext_database_with_both_keys_ends_on_the_new_key(tmp_path):  # A2 + A5
    path = tmp_path / "deck.db"
    _seed(path)
    _start(path, db_key=K1, db_key_new=K2)
    assert _opens_with(path, K2) and not _opens_with(path, K1)


def test_the_key_is_never_in_settings_repr_or_errors(tmp_path):  # A6
    settings = _settings(tmp_path / "deck.db", db_key=K1, db_key_new=K2)
    assert K1 not in repr(settings) and K2 not in repr(settings)
    for bad in (K1[:-1], "x" * 64):
        with pytest.raises(RuntimeError) as refused:
            _start(tmp_path / "deck.db", db_key=bad)
        assert bad not in str(refused.value)


def test_the_raw_files_hold_no_plaintext(tmp_path):  # A7
    path = tmp_path / "deck.db"
    old = sqlite3.connect(path)  # a pre-014 deck: its migrations make (encrypted) backups
    with old:
        old.executescript(OLD_SCHEMA)
        old.execute(
            "INSERT INTO card VALUES (?, 'old-front', 'old-back', '2026-11-19 00:00:00', "
            "'2026-11-19 00:00:00', '2026-11-22 00:00:00', 2, NULL, 3.1, 5.2, NULL)",
            (CARD,),
        )
    old.close()
    _start(path, db_key=K1, owner_email="owner-marker@example.com")
    secrets = _seed(path, K1)
    _start(path, db_key=K1)

    files = [
        p for p in tmp_path.iterdir() if p.name.startswith("deck.db") and ".pre-032-" not in p.name
    ]
    assert any(p.name.endswith(".bak") for p in files), "expected the migration backups"
    needles = [*EMAILS, *MARKERS, "owner-marker", "old-front", *secrets, *auth.PREFIX.values()]
    for file in files:
        content = file.read_bytes()
        assert not content.startswith(b"SQLite format 3"), file.name
        for needle in needles:
            assert needle.encode() not in content, (file.name, needle)

    with Session(make_engine(f"sqlite:///{path}", key=K1)) as session:  # still readable
        assert {note.fields["front"] for note in session.exec(select(Note))} == {
            "old-front",
            MARKERS[0],
        }
