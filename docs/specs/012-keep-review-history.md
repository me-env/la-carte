# 012 — Keep review history when a card is deleted

Status: done
Owners: api-engineer. No iOS work.
Depends on: 007's API part (streak, merged). Backlog #16.
Design reference: none (no UI).

**Parallelism.** Touches only `api/src/la_carte_api/models.py` (`ReviewLog`), `db.py` (startup migration),
`deck.py` (`delete_card` comment only), `api/tests/`, `docs/architecture.md`. Safe to run now, next to every iOS
spec. Must merge before 013's API step (both change `ReviewLog` and the migration in `db.py`).

## Goal
Deleting a card no longer erases the days you studied: `streak` and `reviewed_today` (widget, `/stats`,
`deck_stats`) stay the same after a delete. Today `ReviewLog.card_id` has `ON DELETE CASCADE`, so deleting a card
removes its reviews and can break a past streak.

## Decision
`ReviewLog.card_id` stays a UUID column (indexed, not null) but **without a foreign key**: the log keeps the id
of a card that no longer exists. Why not `SET NULL`: `reviewed_today` counts *distinct* `card_id`s, and NULLs
would make two deleted cards count as zero; keeping the id keeps that count exact with no query change.
SQLite can't drop a constraint, so existing databases get a one-time table rebuild at startup.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Review card A today, delete A: `GET /stats` still returns `reviewed_today: 1` and the same `streak` as before the delete | pytest (REST) |
| 2 | Review a card yesterday and today, delete it: `streak` stays 2 (`deck_stats` MCP tool too) | pytest (deck + MCP) |
| 3 | `DELETE /cards/{id}` still returns 204, the card is gone from `/cards` and `/cards/due`, and its `ReviewLog` rows still exist with the same `card_id`, `rating`, `reviewed_at` | pytest |
| 4 | **Migration**: starting the API on a database whose `reviewlog` table has the old `FOREIGN KEY … ON DELETE CASCADE` rebuilds the table with no foreign key, keeps every row (ids, values) and the indexes on `card_id` and `reviewed_at`; `PRAGMA foreign_key_list(reviewlog)` is then empty | pytest (builds an old-schema file DB in `tmp_path`, then `make_engine`) |
| 5 | The migration is idempotent: starting twice changes nothing; a fresh database is created without the foreign key and skips the rebuild | pytest |
| 6 | The rebuild runs in one transaction with `PRAGMA foreign_keys=OFF` for its duration; if it fails, the old table is left intact | review |
| 7 | `docs/architecture.md` says review history survives card deletion and documents the startup migration rule (below) | review |

## TCA shape (iOS)
None.

## API / MCP changes
- `models.py`: `card_id: UUID = Field(sa_column=Column(Uuid, nullable=False, index=True))` (no `ForeignKey`).
- `db.py`: after `create_all`, `_migrate(engine)`: if `PRAGMA foreign_key_list(reviewlog)` is non-empty, rebuild
  (`CREATE TABLE reviewlog_new` from the model's DDL, `INSERT … SELECT`, `DROP`, `ALTER TABLE … RENAME`, recreate
  indexes). Plain SQL, no Alembic: one deck, one SQLite file.
- No contract change: REST and MCP responses are unchanged. `delete_card` docstring (MCP) adds: "Its review history
  is kept for stats."

## Docs change (same PR)
`docs/architecture.md`, API section, new rule: "Schema changes on existing tables go in `db._migrate`: idempotent,
checked with `PRAGMA`, run at startup after `create_all`. Review history (`ReviewLog`) is never deleted."

## Accessibility identifiers
None.

## Out of scope
- Exposing review history over REST/MCP; purging old logs; Alembic or any migration framework.
