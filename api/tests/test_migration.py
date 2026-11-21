"""Spec 012: the startup migration that drops reviewlog's ON DELETE CASCADE foreign key."""

import sqlite3

import pytest
from sqlmodel import Session

from la_carte_api import db as migration
from la_carte_api import deck
from la_carte_api.db import make_engine

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
        "reviews": db.execute("SELECT * FROM reviewlog ORDER BY id").fetchall(),
        "cards": db.execute("SELECT * FROM card").fetchall(),
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
    assert len(list(tmp_path.glob("*.bak"))) == 1  # second start: no rebuild, no backup


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
    [backup] = tmp_path.glob("*.bak")
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
