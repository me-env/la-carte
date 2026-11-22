"""Startup migrations: spec 012 (reviewlog loses its FK), 013 (confidence), 014 (notes)."""

import sqlite3
from datetime import UTC, datetime
from uuid import UUID

import pytest
from sqlmodel import Session

from la_carte_api import db as migration
from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.models import Direction, NoteCreate, NoteType

# The schema as created before spec 012 (`.schema` of a database made by the old models).
OLD_SCHEMA = """
CREATE TABLE card (
    id CHAR(32) NOT NULL, front VARCHAR NOT NULL, back VARCHAR NOT NULL,
    created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, due DATETIME NOT NULL,
    fsrs_state INTEGER NOT NULL, step INTEGER, stability FLOAT, difficulty FLOAT,
    last_review DATETIME, PRIMARY KEY (id)
);
CREATE INDEX ix_card_due ON card (due);
CREATE TABLE reviewlog (
    id INTEGER NOT NULL, card_id CHAR(32), rating VARCHAR(5) NOT NULL,
    reviewed_at DATETIME NOT NULL, PRIMARY KEY (id),
    FOREIGN KEY(card_id) REFERENCES card (id) ON DELETE CASCADE
);
CREATE INDEX ix_reviewlog_card_id ON reviewlog (card_id);
CREATE INDEX ix_reviewlog_reviewed_at ON reviewlog (reviewed_at);
"""
CARD = "0123456789abcdef0123456789abcdef"
# Columns kept by every migration (spec 014 moves front/back to the note).
CARD_COLUMNS = (
    "id, created_at, updated_at, due, fsrs_state, step, stability, difficulty, last_review"
)
REVIEWS = [
    (3, CARD, "good", "2026-11-20 08:00:00.000000"),
    (7, CARD, "again", "2026-11-21 09:30:00.000000"),
]


def _old_db(path, reviews=REVIEWS) -> str:
    db = sqlite3.connect(path)
    with db:
        db.executescript(OLD_SCHEMA)
        db.execute(
            "INSERT INTO card VALUES (?, 'chat', 'cat', '2026-11-19 00:00:00.000000', "
            "'2026-11-19 00:00:00.000000', '2026-11-22 00:00:00.000000', 2, NULL, 3.1, 5.2, "
            "'2026-11-21 09:30:00.000000')",
            (CARD,),
        )
        db.executemany("INSERT INTO reviewlog VALUES (?, ?, ?, ?)", reviews)
    db.close()
    return f"sqlite:///{path}"


def _snapshot(path) -> dict:
    db = sqlite3.connect(path)
    snapshot = {
        "foreign_keys": db.execute("PRAGMA foreign_key_list(reviewlog)").fetchall(),
        "indexes": sorted(r[1] for r in db.execute("PRAGMA index_list(reviewlog)")),
        "card_id_notnull": [r[3] for r in db.execute("PRAGMA table_info(reviewlog)")][1],
        "sql": sorted(r[0] for r in db.execute("SELECT sql FROM sqlite_master WHERE sql")),
        "reviews": db.execute(
            "SELECT id, card_id, rating, reviewed_at FROM reviewlog ORDER BY id"
        ).fetchall(),
        "cards": db.execute(f"SELECT {CARD_COLUMNS} FROM card").fetchall(),
    }
    db.close()
    return snapshot


def test_rebuilds_an_old_database_keeping_every_row(tmp_path):
    path = tmp_path / "deck.db"
    url = _old_db(path)
    before = _snapshot(path)
    assert before["foreign_keys"]

    make_engine(url).dispose()

    after = _snapshot(path)
    assert after["foreign_keys"] == []
    assert after["indexes"] == ["ix_reviewlog_card_id", "ix_reviewlog_reviewed_at"]
    assert after["card_id_notnull"] == 1
    assert (after["reviews"], after["cards"]) == (before["reviews"], before["cards"])
    assert not any("reviewlog_new" in sql for sql in after["sql"])
    [backup] = tmp_path.glob("deck.db.pre-012-*.bak")
    assert _snapshot(backup) == before  # untouched copy of the old file


def test_migrated_database_keeps_history_after_delete(tmp_path):
    engine = make_engine(_old_db(tmp_path / "deck.db"))
    with Session(engine) as session:
        [card] = deck.list_cards(session)
        deck.delete_card(session, card.id)
        assert deck.list_cards(session) == []
    engine.dispose()
    assert _snapshot(tmp_path / "deck.db")["reviews"] == REVIEWS


def test_is_idempotent(tmp_path):
    path = tmp_path / "deck.db"
    url = _old_db(path)
    make_engine(url).dispose()
    once = _snapshot(path)

    make_engine(url).dispose()

    assert _snapshot(path) == once
    assert len(list(tmp_path.glob("*.bak"))) == 4  # pre-012, -014, -015, -021; second start: none


def test_fresh_database_has_no_foreign_key_and_skips_the_rebuild(tmp_path):
    make_engine(f"sqlite:///{tmp_path / 'deck.db'}").dispose()
    snapshot = _snapshot(tmp_path / "deck.db")
    assert snapshot["foreign_keys"] == []
    assert snapshot["indexes"] == ["ix_reviewlog_card_id", "ix_reviewlog_reviewed_at"]
    assert list(tmp_path.glob("*.bak")) == []


def test_rebuild_skips_reviews_without_a_card_id(tmp_path, caplog):
    # Orphans can't go into the new NOT NULL column; they must not block startup.
    path = tmp_path / "deck.db"
    url = _old_db(path, [*REVIEWS, (9, None, "good", "2026-11-21 10:00:00.000000")])

    make_engine(url).dispose()

    snapshot = _snapshot(path)
    assert (snapshot["foreign_keys"], snapshot["reviews"]) == ([], REVIEWS)
    assert "skipped 1 review(s) with no card_id" in caplog.text
    [backup] = tmp_path.glob("*.pre-012-*.bak")
    assert len(_snapshot(backup)["reviews"]) == 3  # the orphan stays in the backup


def test_failed_rebuild_leaves_the_old_table_intact(tmp_path, monkeypatch):
    path = tmp_path / "deck.db"
    url = _old_db(path)
    before = _snapshot(path)

    def fail_after_copy(db, dialect):
        db.execute("CREATE TABLE reviewlog_new (id INTEGER)")
        db.execute("DROP TABLE reviewlog")
        raise RuntimeError("boom")

    monkeypatch.setattr(migration, "_rebuild_reviewlog", fail_after_copy)
    with pytest.raises(RuntimeError, match="boom"):
        make_engine(url)

    assert _snapshot(path) == before


# --- spec 013: reviewlog.confidence -------------------------------------------------------------


def _confidence(path) -> list:
    db = sqlite3.connect(path)
    info = {r[1]: r for r in db.execute("PRAGMA table_info(reviewlog)")}["confidence"]
    rows = db.execute("SELECT confidence FROM reviewlog ORDER BY id").fetchall()
    db.close()
    return [(info[2], info[3]), rows]  # (type, notnull), values


def _db_012(path) -> str:
    """A database as created by spec 012's models: reviewlog without a foreign key or confidence."""
    url = _old_db(path)
    db = sqlite3.connect(path)
    with db:
        db.executescript(
            "CREATE TABLE r (id INTEGER NOT NULL, card_id CHAR(32) NOT NULL, rating VARCHAR(5) "
            "NOT NULL, reviewed_at DATETIME NOT NULL, PRIMARY KEY (id));"
            "INSERT INTO r SELECT * FROM reviewlog; DROP TABLE reviewlog;"
            "ALTER TABLE r RENAME TO reviewlog;"
            "CREATE INDEX ix_reviewlog_card_id ON reviewlog (card_id);"
            "CREATE INDEX ix_reviewlog_reviewed_at ON reviewlog (reviewed_at);"
        )
    db.close()
    return url


def test_adds_a_nullable_confidence_column_to_a_012_database(tmp_path):
    path = tmp_path / "deck.db"
    url = _db_012(path)
    before = _snapshot(path)

    make_engine(url).dispose()

    assert _confidence(path) == [("FLOAT", 0), [(None,), (None,)]]
    assert _snapshot(path)["reviews"] == before["reviews"] == REVIEWS
    make_engine(url).dispose()  # idempotent
    assert _confidence(path) == [("FLOAT", 0), [(None,), (None,)]]


def test_a_pre_012_database_gets_both_steps(tmp_path):
    path = tmp_path / "deck.db"
    make_engine(_old_db(path)).dispose()
    assert _snapshot(path)["foreign_keys"] == []
    assert _confidence(path) == [("FLOAT", 0), [(None,), (None,)]]


def test_fresh_database_has_the_confidence_column(tmp_path):
    make_engine(f"sqlite:///{tmp_path / 'deck.db'}").dispose()
    assert _confidence(tmp_path / "deck.db") == [("FLOAT", 0), []]


# --- spec 014: cards become directions over notes ----------------------------------------------

OTHER = "fedcba9876543210fedcba9876543210"


def _main_db(path, with_confidence=False) -> str:
    """A database as created by main before spec 014 (012's reviewlog, two cards), optionally
    with 013's confidence column."""
    url = _db_012(path)
    db = sqlite3.connect(path)
    with db:
        db.execute(
            "INSERT INTO card VALUES (?, 'Été', 'summer', '2026-11-18 00:00:00.000000', "
            "'2026-11-18 00:00:00.000000', '2026-11-18 00:00:00.000000', 1, 0, NULL, NULL, NULL)",
            (OTHER,),
        )
        if with_confidence:
            db.execute("ALTER TABLE reviewlog ADD COLUMN confidence FLOAT")
            db.execute("UPDATE reviewlog SET confidence = 0.5 WHERE id = 7")
    db.close()
    return url


def _notes_snapshot(path) -> dict:
    db = sqlite3.connect(path)
    snapshot = {
        "notes": db.execute("SELECT id, type, fields, created_at, updated_at FROM note").fetchall(),
        "directions": db.execute("SELECT id, note_id, prompt, answer FROM card").fetchall(),
        "card_columns": [r[1] for r in db.execute("PRAGMA table_info(card)")],
        "card_fk": [(r[2], r[3], r[4], r[6]) for r in db.execute("PRAGMA foreign_key_list(card)")],
        "card_indexes": sorted(r[1] for r in db.execute("PRAGMA index_list(card)")),
        "confidence": db.execute("SELECT id, confidence FROM reviewlog ORDER BY id").fetchall(),
    }
    db.close()
    return snapshot


@pytest.mark.parametrize("with_confidence", [False, True])
def test_cards_become_basic_notes_keeping_ids_schedule_and_history(tmp_path, with_confidence):
    path = tmp_path / "deck.db"
    url = _main_db(path, with_confidence)
    before = _snapshot(path)

    engine = make_engine(url)

    after, notes = _snapshot(path), _notes_snapshot(path)
    assert (after["cards"], after["reviews"]) == (before["cards"], before["reviews"])
    assert sorted(notes["notes"]) == sorted([
        (CARD, "basic", '{"front":"chat","back":"cat"}', *before["cards"][0][1:3]),
        (OTHER, "basic", '{"front":"Été","back":"summer"}', *before["cards"][1][1:3]),
    ])  # fmt: skip
    assert sorted(notes["directions"]) == sorted(
        (i, i, '["front"]', '["back"]') for i in (CARD, OTHER)
    )
    assert "front" not in notes["card_columns"] and "back" not in notes["card_columns"]
    assert notes["card_fk"] == [("note", "note_id", "id", "CASCADE")]
    assert notes["card_indexes"] == ["ix_card_due", "ix_card_note_id", "sqlite_autoindex_card_1"]
    assert notes["confidence"] == [(3, None), (7, 0.5 if with_confidence else None)]
    [backup] = tmp_path.glob("deck.db.pre-014-*.bak")
    assert _snapshot(backup) == before  # untouched copy of the old file
    assert list(tmp_path.glob("*.pre-012-*.bak")) == []

    with Session(engine) as session:  # the app reads it as before
        cards = {c.front: c for c in deck.list_cards(session, query="")}
        assert (cards["chat"].back, cards["chat"].note_id, cards["chat"].state) == (
            "cat", UUID(CARD), "review",
        )  # fmt: skip
        assert deck.list_cards(session, query="été")[0].back == "summer"
        stats = deck.stats(session, now=datetime(2026, 11, 21, 12, tzinfo=UTC))
        assert (stats.total, stats.reviewed_today, stats.streak) == (2, 1, 2)
    engine.dispose()


def test_notes_migration_is_idempotent(tmp_path):
    path = tmp_path / "deck.db"
    url = _main_db(path)
    make_engine(url).dispose()
    once = (_snapshot(path), _notes_snapshot(path))

    make_engine(url).dispose()

    assert (_snapshot(path), _notes_snapshot(path)) == once
    assert len(list(tmp_path.glob("*.bak"))) == 3  # pre-014, pre-015, pre-021; second start: none


def test_failed_notes_migration_leaves_the_old_tables_intact(tmp_path, monkeypatch):
    path = tmp_path / "deck.db"
    url = _main_db(path)
    before = _snapshot(path)
    tables = sqlite3.connect(path).execute("SELECT name FROM sqlite_master").fetchall()

    def fail_mid_rebuild(db, dialect):
        db.execute("CREATE TABLE note (id CHAR(32))")
        db.execute(f"INSERT INTO note VALUES ('{CARD}')")
        db.execute("DROP TABLE card")
        raise RuntimeError("boom")

    monkeypatch.setattr(migration, "_cards_to_notes", fail_mid_rebuild)
    with pytest.raises(RuntimeError, match="boom"):
        make_engine(url)

    assert _snapshot(path) == before
    assert sqlite3.connect(path).execute("SELECT name FROM sqlite_master").fetchall() == tables

    monkeypatch.undo()  # the next start migrates normally
    make_engine(url).dispose()
    assert len(_notes_snapshot(path)["notes"]) == 2


# --- spec 014a amendment: person role/context fold into description ---------------------------


def test_person_role_and_context_fold_into_description(tmp_path):
    path = tmp_path / "deck.db"
    url = f"sqlite:///{path}"
    engine = make_engine(url)
    with Session(engine) as session:
        person = NoteCreate(
            type=NoteType.person,
            fields={"name": "Ada Example", "photo": "https://example.org/a.jpg"},
            directions=[Direction(prompt=["photo"]), Direction(prompt=["name"])],
        )
        [note] = deck.add_notes(session, [person]).added
    engine.dispose()
    photo, name = (card.id.hex for card in note.cards)
    old = sqlite3.connect(path)  # as written before the amendment: role, context, partial answers
    old.execute(
        "UPDATE note SET fields = json_set(fields, '$.role', 'CEO', '$.context', 'met in Paris')"
    )
    old.execute(
        """UPDATE card SET prompt = '["role"]', answer = '["name"]' WHERE id = ?""", (name,)
    )
    old.execute("""UPDATE card SET answer = '["name"]' WHERE id = ?""", (photo,))
    old.commit()
    old.close()

    engine = make_engine(url)

    with Session(engine) as session:
        folded = deck.get_note(session, note.id)
    assert folded.fields == {
        "name": "Ada Example",
        "photo": "https://example.org/a.jpg",
        "description": "CEO — met in Paris",
    }
    assert [(c.id.hex, c.prompt, c.answer) for c in folded.cards] == [
        (photo, ["photo"], ["name", "description"]),
        (name, ["description"], ["photo", "name"]),
    ]
    assert len(list(tmp_path.glob("deck.db.pre-014a-*.bak"))) == 1
    engine.dispose()
    make_engine(url).dispose()  # idempotent: no second backup
    assert len(list(tmp_path.glob("*.bak"))) == 1
