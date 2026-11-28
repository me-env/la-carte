"""Spec 030a: users, bearer tokens, scoped data, `/me`, migration 030 (AC numbers in comments)."""

import asyncio
import hashlib
import logging
import re
import sqlite3
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from conftest import add_user, bearer, mcp_client, token_for
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient
from sqlalchemy import inspect, text
from sqlmodel import Session, select

from la_carte_api import app as app_module
from la_carte_api import auth, deck, rest
from la_carte_api.app import PUBLIC_PATHS, create_app, prune_daily
from la_carte_api.config import Settings
from la_carte_api.db import NEEDS_OWNER, MigrationRefused, make_engine
from la_carte_api.models import (
    ActivityEvent,
    ApiToken,
    Card,
    Direction,
    Identity,
    NoteCreate,
    Rating,
    ReportCreate,
    TokenKind,
    TokenScope,
    User,
    utcnow,
)

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


MCP_HEADERS = {"Accept": "application/json, text/event-stream"}
DOCS = {"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"}  # FastAPI's own, public
A_EMAIL, B_EMAIL, OWNER_EMAIL = "a@example.com", "b@example.com", "owner@example.com"


def _app(**settings) -> TestClient:
    return TestClient(create_app(Settings(database_url="sqlite://", _env_file=None, **settings)))


def _rest_routes(app) -> list[tuple[str, str]]:
    """Every REST route of the app but the public ones (FastAPI nests the included router)."""
    routes = [*app.routes, *rest.router.routes]
    assert any(type(r).__name__ == "_IncludedRouter" for r in app.routes), "router not included"
    return sorted(
        (method, route.path)
        for route in routes
        if isinstance(route, APIRoute) and route.path not in PUBLIC_PATHS | DOCS
        for method in route.methods
    )


def _url(path: str) -> str:
    """A route path with its ids filled in (any id: auth runs before the lookup)."""
    return (
        path.replace("{note_id}", str(uuid4()))
        .replace("{card_id}", str(uuid4()))
        .replace("{token_id}", str(uuid4()))
    )


def _mcp(client: TestClient, method: str, params: dict | None = None, token: str | None = None):
    headers = MCP_HEADERS | (bearer(token) if token else {})
    body = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    return client.post("/mcp", json=body, headers=headers)


def _basic(front: str, back: str = "x") -> NoteCreate:
    return NoteCreate(type="basic", fields={"front": front, "back": back})


def _event(card_id: UUID | None = None, event_id: UUID | None = None, kind="card_shown") -> dict:
    return {
        "id": str(event_id or uuid4()), "kind": kind, "at": utcnow().isoformat(),
        "tz": "Europe/Paris", "session": str(uuid4()), "app_version": "1.0", "build": "1",
        "os": "iOS 26.0", "card_id": str(card_id) if card_id else None, "data": {},
    }  # fmt: skip


# --- AC 1-3: bearer tokens ----------------------------------------------------------------------


def test_every_rest_route_needs_a_valid_token():  # AC 1
    with _app() as client:
        engine = client.app.state.engine
        user = add_user(engine, A_EMAIL)
        revoked, expired = token_for(engine, user), token_for(engine, user)
        with Session(engine) as session:
            for raw, field in ((revoked, "revoked_at"), (expired, "expires_at")):
                token = session.exec(
                    select(ApiToken).where(ApiToken.hash == auth.token_hash(raw))
                ).one()
                setattr(token, field, utcnow() - timedelta(seconds=1))
                session.add(token)
            session.commit()
        refresh = None
        with Session(engine) as session:
            refresh = auth.mint(session, user, TokenKind.refresh, TokenScope.deck)
        routes = _rest_routes(client.app)
        assert ("DELETE", "/me") in routes and ("GET", "/notes") in routes
        for headers in (
            {}, bearer("lc_pat_unknown"), bearer(revoked), bearer(expired), bearer(refresh),
            {"Authorization": "Basic abc"},
        ):  # fmt: skip
            for method, path in routes:
                response = client.request(method, _url(path), headers=headers, json={})
                assert response.status_code == 401, (method, path, headers)
                assert response.json() == {"detail": "Unauthorized"}
                assert response.headers["www-authenticate"] == "Bearer"
        assert client.get("/health").status_code == 200
        assert client.get("/icon.png").status_code == 200


def test_mcp_needs_a_deck_token_and_lists_tools_over_http():  # AC 2
    with _app(public_url="https://carte.example.com") as client:
        engine = client.app.state.engine
        token = token_for(engine, add_user(engine, A_EMAIL))
        for headers in ({}, bearer("lc_pat_unknown")):
            response = client.post("/mcp", json={}, headers=MCP_HEADERS | headers)
            assert response.status_code == 401
            assert (
                'resource_metadata="https://carte.example.com/.well-known/oauth-protected-'
                'resource/mcp"' in response.headers["www-authenticate"]
            )
        listed = _mcp(client, "tools/list", token=token)
        assert listed.status_code == 200
        assert "add_notes" in {tool["name"] for tool in listed.json()["result"]["tools"]}
        metadata = client.get("/.well-known/oauth-protected-resource/mcp").json()
        assert metadata["resource"] == "https://carte.example.com/mcp"


def test_a_stats_token_reads_only_the_stats():  # AC 3
    with _app() as client:
        engine = client.app.state.engine
        stats = token_for(engine, add_user(engine, A_EMAIL), TokenScope.stats)
        assert client.get("/stats", headers=bearer(stats)).status_code == 200
        for method, path in _rest_routes(client.app):
            if (method, path) != ("GET", "/stats"):
                response = client.request(method, _url(path), headers=bearer(stats), json={})
                assert response.status_code == 403, (method, path)
                assert response.json() == {"detail": "Insufficient scope"}
        assert _mcp(client, "tools/list", token=stats).status_code in (401, 403)


def test_verify_touches_last_used_at_at_most_hourly(session):
    user = add_user(session.get_bind(), A_EMAIL)
    raw = auth.mint(session, user, TokenKind.pat, TokenScope.deck)
    now = utcnow()
    assert auth.verify(session, raw, now).user_id == user
    token = session.exec(select(ApiToken)).one()
    assert token.last_used_at == now and session.get(User, user).last_seen_at == now
    auth.verify(session, raw, now + timedelta(minutes=59))
    assert session.exec(select(ApiToken)).one().last_used_at == now
    auth.verify(session, raw, now + timedelta(hours=1))
    assert session.exec(select(ApiToken)).one().last_used_at == now + timedelta(hours=1)
    assert raw.startswith("lc_pat_") and len(raw) == len("lc_pat_") + 43
    assert token.hash == hashlib.sha256(raw.encode()).hexdigest()


# --- AC 4-5: two users, nothing shared ----------------------------------------------------------


def _fill(client: TestClient, token: str) -> dict:
    """Notes, cards, a review, a report, feedback, activity and a milestone, through the API."""
    h = bearer(token)
    notes = [
        client.post("/notes", json={"type": "basic", "fields": {"front": f, "back": "b"}},
                    headers=h).json()
        for f in ("chat", "chien", "cheval")
    ]  # fmt: skip
    cards = [card["id"] for note in notes for card in note["cards"]]
    client.post(f"/cards/{cards[0]}/review", json={"rating": "good"}, headers=h)
    report = client.post(f"/cards/{cards[2]}/report", json={"reason": "wrong"}, headers=h).json()
    event = _event(UUID(cards[0]))
    client.post("/activity", json={"events": [event]}, headers=h)
    return {"notes": [n["id"] for n in notes], "cards": cards, "report": report["id"],
            "event": event["id"]}  # fmt: skip


def _owned_rows(engine, user_id: UUID) -> dict[str, list]:
    """Every row the user owns (and their user row and tokens), as stored."""
    tables = inspect(engine).get_table_names()
    with engine.connect() as connection:
        rows = {
            table: sorted(
                map(tuple, connection.execute(
                    text(f'SELECT * FROM "{table}" WHERE user_id = :u'), {"u": user_id.hex}
                ))
            )
            for table in tables
            if "user_id" in {c["name"] for c in inspect(engine).get_columns(table)}
        }  # fmt: skip
        rows["user"] = list(
            map(tuple, connection.execute(text('SELECT * FROM "user" WHERE id = :u'),
                                          {"u": user_id.hex}))
        )  # fmt: skip
    return rows


def _rest_cases(a: dict, b_card: str) -> dict:
    """(method, path) -> (url, body, check): what B gets when using A's ids."""
    note, card = a["notes"][0], a["cards"][0]
    a_ids = set(a["notes"]) | set(a["cards"]) | {a["report"], a["event"]}

    def none_of_a(response):
        assert response.status_code in (200, 201), response.text
        assert not any(i in response.text for i in a_ids), response.text

    def not_found(response):
        assert response.status_code == 404, response.text

    def rejected(response):
        assert response.json() == {"stored": 0, "duplicates": 0, "rejected": 1}

    return {
        ("GET", "/notes"): ("/notes", None, none_of_a),
        ("POST", "/notes"): ("/notes", {"type": "basic", "fields": {"front": "chat", "back": "c"}},
                             none_of_a),
        ("GET", "/notes/{note_id}"): (f"/notes/{note}", None, not_found),
        ("PATCH", "/notes/{note_id}"): (f"/notes/{note}", {"fields": {"back": "B"}}, not_found),
        ("DELETE", "/notes/{note_id}"): (f"/notes/{note}", None, not_found),
        ("GET", "/cards"): ("/cards", None, none_of_a),
        ("POST", "/cards"): ("/cards", {"front": "chien", "back": "dog"}, none_of_a),
        ("GET", "/cards/due"): ("/cards/due", None, none_of_a),
        ("GET", "/cards/{card_id}"): (f"/cards/{card}", None, not_found),
        ("PATCH", "/cards/{card_id}"): (f"/cards/{card}", {"back": "B"}, not_found),
        ("DELETE", "/cards/{card_id}"): (f"/cards/{card}", None, not_found),
        ("POST", "/cards/{card_id}/review"): (f"/cards/{card}/review", {"rating": "again"},
                                              not_found),
        ("POST", "/cards/{card_id}/report"): (f"/cards/{card}/report", {"reason": "drop"},
                                              not_found),
        ("GET", "/stats"): ("/stats", None, none_of_a),
        ("POST", "/activity"): (
            "/activity", {"events": [_event(UUID(b_card), UUID(a["event"]))]}, rejected
        ),
        ("GET", "/activity"): ("/activity", None, none_of_a),
        ("GET", "/me"): ("/me", None, none_of_a),
        ("GET", "/me/tokens"): ("/me/tokens", None, none_of_a),
        ("DELETE", "/me/tokens/{token_id}"): (f"/me/tokens/{a['token_id']}", None, not_found),
        ("DELETE", "/me"): ("/me", None, lambda r: r.status_code == 204 or pytest.fail(r.text)),
    }  # fmt: skip


def test_cross_user_matrix_rest():  # AC 4
    with _app() as client:
        engine = client.app.state.engine
        user_a, user_b = add_user(engine, A_EMAIL), add_user(engine, B_EMAIL)
        token_a, token_b = token_for(engine, user_a), token_for(engine, user_b)
        a, b = _fill(client, token_a), _fill(client, token_b)
        with Session(engine) as session:
            deck.set_milestone(session, user_a, 7)
            deck.send_feedback(session, user_a, "A's feedback")
            a["token_id"] = str(session.exec(select(ApiToken.id).where(
                ApiToken.user_id == user_a)).one())  # fmt: skip
        before = _owned_rows(engine, user_a)

        cases = _rest_cases(a, b["cards"][0])
        routes = _rest_routes(client.app)
        assert sorted(cases) == routes, "every REST route needs a cross-user case"
        for key in sorted(cases, key=lambda k: k == ("DELETE", "/me")):  # deleting B goes last
            url, body, check = cases[key]
            check(client.request(key[0], url, json=body, headers=bearer(token_b)))
            assert _owned_rows(engine, user_a) == before, key

        stats_b = client.get("/stats", headers=bearer(token_a)).json()
        assert stats_b["milestone"] == 7  # A's own setting, untouched


async def test_cross_user_matrix_mcp(engine):  # AC 4
    user_a, user_b = add_user(engine, A_EMAIL), add_user(engine, B_EMAIL)
    with Session(engine) as session:
        notes = deck.add_notes(session, user_a, [_basic("chat"), _basic("chien")]).added
        a_note, a_card = notes[0].id, notes[0].cards[0].id
        deck.review_card(session, user_a, a_card, Rating.again)
        a_report = deck.report_card(session, user_a, notes[1].cards[0].id,
                                    ReportCreate(reason="wrong"))[0].id  # fmt: skip
        a_feedback = deck.send_feedback(session, user_a, "A's feedback").id
        deck.ingest_activity(session, user_a, [_event(a_card)])
        deck.set_milestone(session, user_a, 7)
        a_ids = {str(i) for i in (a_note, a_card, a_report, a_feedback, notes[1].id)}
        a_ids |= {str(c.id) for n in notes for c in n.cards}
    before = _owned_rows(engine, user_a)

    def nothing_of_a(result):
        assert not result.is_error, result.content
        assert not any(i in str(result.structured_content) for i in a_ids)

    def not_found(result):
        assert result.is_error and _not_found(result.content[0].text), result

    cases = {
        "add_notes": ({"notes": [{"type": "basic", "fields": {"front": "chat", "back": "c"}}]},
                      lambda r: nothing_of_a(r) or r.structured_content["skipped"] == []
                      or pytest.fail("skipped A's note")),
        "find_notes": ({}, nothing_of_a),
        "update_note": ({"note_id": str(a_note), "fields": {"back": "B"}}, not_found),
        "add_direction": ({"note_id": str(a_note), "prompt": ["back"]}, not_found),
        "remove_direction": ({"card_id": str(a_card)}, not_found),
        "delete_note": ({"note_id": str(a_note)}, not_found),
        "due_cards": ({}, nothing_of_a),
        "review_card": ({"card_id": str(a_card), "rating": "good"}, not_found),
        "deck_stats": ({}, lambda r: r.structured_content["history"] == "p"
                       or pytest.fail("A's reviews in B's history")),
        "new_card_milestone": ({}, lambda r: r.structured_content == {"milestone": 15}
                               or pytest.fail("A's milestone")),
        "list_reports": ({"status": "all"}, nothing_of_a),
        "update_report": ({"report_id": str(a_report), "outcome": "kept", "note": "n"},
                          not_found),
        "send_feedback": ({"message": "B's feedback"}, nothing_of_a),
        "list_feedback": ({"status": "all"}, nothing_of_a),
        "close_feedback": ({"feedback_id": str(a_feedback)}, not_found),
        "activity_log": ({}, nothing_of_a),
        "review_history": ({}, nothing_of_a),
        "struggling_cards": ({}, nothing_of_a),
    }  # fmt: skip
    async with mcp_client(engine, user_b) as client:
        tools = {tool.name for tool in (await client.list_tools()).tools}
        assert set(cases) == tools, "every MCP tool needs a cross-user case"
        for name, (arguments, check) in cases.items():
            check(await client.call_tool(name, arguments))
            assert _owned_rows(engine, user_a) == before, name
        user_not_found = await client.call_tool("activity_log", {"user": A_EMAIL})
        assert user_not_found.is_error and "user not found" in user_not_found.content[0].text
        by_card = await client.call_tool("review_history", {"card_id": str(a_card)})
        assert by_card.structured_content["result"] == []
        await client.call_tool("new_card_milestone", {"value": 3})
    assert _owned_rows(engine, user_a) == before


def test_each_user_has_their_own_queue_stats_and_settings(engine, session):  # AC 5
    user_a, user_b = add_user(engine, A_EMAIL), add_user(engine, B_EMAIL)
    now = utcnow()
    month_ago = now - timedelta(days=30)
    [note] = deck.add_notes(session, user_a, [_basic("chat")], now=month_ago).added
    for card in note.cards:
        deck.review_card(session, user_a, card.id, Rating.good, now=now - timedelta(days=1))
    deck.set_milestone(session, user_a, 7)

    added = deck.add_notes(session, user_b, [_basic("Chat")], now=now, skip_duplicates=True)
    assert len(added.added) == 1 and added.skipped == []  # not A's duplicate
    stats_a, stats_b = deck.stats(session, user_a, now), deck.stats(session, user_b, now)
    assert (stats_a.total, stats_a.streak, stats_a.milestone) == (2, 1, 7)
    assert (stats_b.total, stats_b.due, stats_b.new, stats_b.streak) == (2, 1, 2, 0)
    assert (stats_b.history, stats_b.reviewed_today, stats_b.milestone) == ("p", 0, 15)
    assert (stats_b.at_risk_total, stats_b.reviews_total) == (0, 0)
    # spec 023: the day loads count only the reviewing user's cards
    for card in session.exec(select(Card).where(Card.user_id == user_a)):
        card.due = now + timedelta(days=4, hours=12)  # day 5 of spec 023's loads
        session.add(card)
    session.commit()
    b_card = added.added[0].cards[0].id
    assert deck._day_loads(session, user_b, b_card, now, 5, 5) == {5: 0}
    assert deck._day_loads(session, user_a, uuid4(), now, 5, 5) == {5: 2}


def test_a_card_always_belongs_to_its_notes_user(client):  # AC 6
    with Session(client.app.state.engine) as session:
        user = add_user(client.app.state.engine, A_EMAIL)
        [note] = deck.add_notes(session, user, [_basic("chat")]).added
        deck.remove_direction(session, user, note.cards[1].id)
        deck.add_direction(session, user, note.id, Direction(prompt=["back"]))
    token = token_for(client.app.state.engine, user)
    patched = client.patch(
        f"/notes/{note.id}",
        json={"directions": [{"prompt": ["front"]}, {"prompt": ["back"]}]},
        headers=bearer(token),
    )
    assert patched.status_code == 200
    rest = client.post("/notes", json={"type": "basic", "fields": {"front": "a", "back": "b"}})
    assert rest.status_code == 201
    with Session(client.app.state.engine) as session:
        cards = session.exec(select(Card)).all()
        assert len(cards) == 4
        for card in cards:
            assert card.user_id == session.get(deck.Note, card.note_id).user_id


# --- AC 7-9: migration 030 and the legacy token -------------------------------------------------

# A database as main wrote it before spec 030 (`.schema` of `make_engine` on that version).
PRE_030 = """
CREATE TABLE note (id CHAR(32) NOT NULL, type VARCHAR(6) NOT NULL, fields JSON NOT NULL,
    created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, PRIMARY KEY (id));
CREATE TABLE reviewlog (id INTEGER NOT NULL, card_id CHAR(32) NOT NULL,
    rating VARCHAR(5) NOT NULL, reviewed_at DATETIME NOT NULL, confidence FLOAT,
    stability_before FLOAT, last_review_before DATETIME, PRIMARY KEY (id));
CREATE INDEX ix_reviewlog_reviewed_at ON reviewlog (reviewed_at);
CREATE INDEX ix_reviewlog_card_id ON reviewlog (card_id);
CREATE TABLE report (id CHAR(32) NOT NULL, card_id CHAR(32) NOT NULL, note_id CHAR(32) NOT NULL,
    reason VARCHAR(12) NOT NULL, comment VARCHAR, status VARCHAR(12) NOT NULL, resolution VARCHAR,
    created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL, resolved_at DATETIME,
    PRIMARY KEY (id));
CREATE INDEX ix_report_card_id ON report (card_id);
CREATE TABLE feedback (id CHAR(32) NOT NULL, kind VARCHAR(9) NOT NULL, message VARCHAR NOT NULL,
    status VARCHAR(4) NOT NULL, resolution VARCHAR, created_at DATETIME NOT NULL,
    closed_at DATETIME, PRIMARY KEY (id));
CREATE TABLE settings (id INTEGER NOT NULL, new_cards_per_day INTEGER NOT NULL,
    PRIMARY KEY (id));
CREATE TABLE activityevent (id CHAR(32) NOT NULL, kind VARCHAR NOT NULL, at DATETIME NOT NULL,
    tz VARCHAR NOT NULL, session CHAR(32) NOT NULL, card_id CHAR(32), app_version VARCHAR NOT NULL,
    build VARCHAR NOT NULL, os VARCHAR NOT NULL, data JSON NOT NULL,
    received_at DATETIME NOT NULL, PRIMARY KEY (id));
CREATE INDEX ix_activityevent_kind ON activityevent (kind);
CREATE INDEX ix_activityevent_at ON activityevent (at);
CREATE INDEX ix_activityevent_card_id ON activityevent (card_id);
CREATE TABLE card (id CHAR(32) NOT NULL, note_id CHAR(32) NOT NULL, prompt JSON NOT NULL,
    answer JSON NOT NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL,
    due DATETIME NOT NULL, fsrs_state INTEGER NOT NULL, step INTEGER, stability FLOAT,
    difficulty FLOAT, last_review DATETIME, PRIMARY KEY (id),
    FOREIGN KEY(note_id) REFERENCES note (id) ON DELETE CASCADE);
CREATE INDEX ix_card_due ON card (due);
CREATE INDEX ix_card_note_id ON card (note_id);
"""
NOTE, CARD = "11111111111111111111111111111111", "22222222222222222222222222222222"
T = "2026-11-20 08:00:00.000000"
OWNED = ("note", "card", "reviewlog", "report", "feedback", "activityevent")


def _pre_030_db(path) -> str:
    db = sqlite3.connect(path)
    with db:
        db.executescript(PRE_030)
        db.execute("INSERT INTO note VALUES (?, 'basic', '{\"front\":\"chat\",\"back\":\"cat\"}',"
                   " ?, ?)", (NOTE, T, T))  # fmt: skip
        db.execute(
            "INSERT INTO card VALUES (?, ?, '[\"front\"]', '[\"back\"]', ?, ?, ?, 2, NULL, 3.1, "
            "5.2, ?)", (CARD, NOTE, T, T, "2026-11-25 08:00:00.000000", T),
        )  # fmt: skip
        db.execute("INSERT INTO reviewlog VALUES (3, ?, 'good', ?, 0.5, NULL, NULL)", (CARD, T))
        db.execute("INSERT INTO report VALUES ('33333333333333333333333333333333', ?, ?, 'wrong',"
                   " NULL, 'open', NULL, ?, ?, NULL)", (CARD, NOTE, T, T))  # fmt: skip
        db.execute("INSERT INTO feedback VALUES ('44444444444444444444444444444444', 'bug', 'm',"
                   " 'open', NULL, ?, NULL)", (T,))  # fmt: skip
        db.execute(
            "INSERT INTO activityevent VALUES ('55555555555555555555555555555555', 'card_shown', ?,"
            " 'UTC', '66666666666666666666666666666666', ?, '1.0', '1', 'iOS', '{}', ?)",
            (T, CARD, T),
        )  # fmt: skip
        db.execute("INSERT INTO settings VALUES (1, 7)")
    db.close()
    return f"sqlite:///{path}"


def _dump(path) -> dict[str, list]:
    """Every owned row without `user_id`, and the milestone."""
    db = sqlite3.connect(path)
    rows = {}
    for table in OWNED:
        columns = [r[1] for r in db.execute(f"PRAGMA table_info({table})") if r[1] != "user_id"]
        rows[table] = sorted(db.execute(f"SELECT {', '.join(columns)} FROM {table}").fetchall())
    rows["milestone"] = db.execute("SELECT new_cards_per_day FROM settings").fetchall()
    db.close()
    return rows


def test_migration_gives_the_deck_to_the_owner(tmp_path):  # AC 7
    path = tmp_path / "deck.db"
    url = _pre_030_db(path)
    before = _dump(path)

    make_engine(url, OWNER_EMAIL).dispose()

    [backup] = tmp_path.glob("deck.db.pre-030-*.bak")
    assert _dump(backup) == before  # an exact copy of the old data
    backup_db = sqlite3.connect(backup)
    assert "user_id" not in {r[1] for r in backup_db.execute("PRAGMA table_info(note)")}
    backup_db.close()
    assert _dump(path) == before  # ids, FSRS, reviews, reports, the milestone: unchanged
    db = sqlite3.connect(path)
    [(owner, email)] = db.execute('SELECT id, email FROM "user"').fetchall()
    assert email == OWNER_EMAIL
    for table in (*OWNED, "settings"):
        assert {r[0] for r in db.execute(f"SELECT user_id FROM {table}")} == {owner}, table
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []
    schema = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type = 'index'")}
    assert {"ix_note_user_id", "ix_card_user_id_due", "ix_feedback_user_id"} <= schema
    db.close()
    engine = make_engine(url, OWNER_EMAIL)
    with Session(engine) as session:
        assert deck.get_milestone(session, UUID(owner)) == 7
        assert deck.get_card(session, UUID(owner), UUID(CARD)).state == "review"
        assert deck.stats(session, UUID(owner)).total == 1
    engine.dispose()
    assert len(list(tmp_path.glob("*.bak"))) == 1  # the second start changed nothing
    assert _dump(path) == before


def test_an_empty_pre_030_database_migrates_without_a_user(tmp_path):
    path = tmp_path / "deck.db"
    db = sqlite3.connect(path)
    db.executescript(PRE_030)
    db.close()
    make_engine(f"sqlite:///{path}").dispose()
    db = sqlite3.connect(path)
    assert db.execute('SELECT count(*) FROM "user"').fetchone() == (0,)
    assert "user_id" in {r[1] for r in db.execute("PRAGMA table_info(card)")}
    db.close()


def test_migration_without_an_owner_refuses_and_changes_nothing(tmp_path):  # AC 8
    path = tmp_path / "deck.db"
    url = _pre_030_db(path)
    original = path.read_bytes()
    with pytest.raises(MigrationRefused, match="set LA_CARTE_OWNER_EMAIL") as refused:
        create_app(Settings(database_url=url, _env_file=None))
    assert str(refused.value) == NEEDS_OWNER
    assert path.read_bytes() == original
    assert list(tmp_path.glob("*.bak")) == []


def test_the_api_token_needs_an_owner_email(tmp_path):  # decision 5
    path = tmp_path / "deck.db"
    with pytest.raises(RuntimeError, match="LA_CARTE_OWNER_EMAIL"):
        create_app(Settings(database_url=f"sqlite:///{path}", api_token="x", _env_file=None))
    assert not path.exists()


def test_the_legacy_token_becomes_the_owners_pat(tmp_path, caplog):  # AC 9
    caplog.set_level(logging.INFO)
    url = _pre_030_db(tmp_path / "deck.db")
    settings = Settings(database_url=url, owner_email=OWNER_EMAIL, api_token="x", _env_file=None)
    with TestClient(create_app(settings)) as client:
        me = client.get("/me", headers=bearer("x"))
        assert me.status_code == 200 and me.json()["email"] == OWNER_EMAIL
        assert me.json()["provider"] is None
        assert [n["id"] for n in client.get("/notes", headers=bearer("x")).json()] == [
            str(UUID(NOTE))
        ]
        stats = _mcp(client, "tools/call", {"name": "deck_stats", "arguments": {}}, "x")
        assert stats.json()["result"]["structuredContent"]["total"] == 1
        [legacy] = client.get("/me/tokens", headers=bearer("x")).json()
        assert (legacy["name"], legacy["scope"], legacy["expires_at"]) == ("legacy", "deck", None)
    assert "LA_CARTE_API_TOKEN is imported" in caplog.text

    db = sqlite3.connect(tmp_path / "deck.db")
    assert db.execute("SELECT hash FROM apitoken").fetchall() == [
        (hashlib.sha256(b"x").hexdigest(),)
    ]
    db.close()

    caplog.clear()
    with TestClient(create_app(settings)) as client:  # restart, variable still set
        assert len(client.get("/me/tokens", headers=bearer("x")).json()) == 1
        assert client.delete(f"/me/tokens/{legacy['id']}", headers=bearer("x")).status_code == 204
        assert client.get("/notes", headers=bearer("x")).status_code == 401
    assert "already imported" in caplog.text
    with TestClient(create_app(settings)) as client:  # the variable does not bring it back
        assert client.get("/notes", headers=bearer("x")).status_code == 401
        assert _mcp(client, "tools/list", token="x").status_code == 401


# --- AC 10-11: /me and personal tokens ---------------------------------------------------------


def test_get_and_delete_me():  # AC 10
    with _app() as client:
        engine = client.app.state.engine
        user_a, user_b = add_user(engine, A_EMAIL), add_user(engine, B_EMAIL)
        token_a, token_b = token_for(engine, user_a), token_for(engine, user_b)
        _fill(client, token_a)
        _fill(client, token_b)
        with Session(engine) as session:
            session.add(Identity(provider="google", subject="a-sub", user_id=user_a))
            session.commit()
            deck.set_milestone(session, user_a, 7)
            deck.send_feedback(session, user_a, "bye")
        other_token = token_for(engine, user_a)
        b_before = _owned_rows(engine, user_b)

        me = client.get("/me", headers=bearer(token_a)).json()
        assert set(me) == {"id", "email", "provider", "created_at"}
        assert (me["id"], me["email"], me["provider"]) == (str(user_a), A_EMAIL, "google")

        assert client.delete("/me", headers=bearer(token_a)).status_code == 204
        assert all(rows == [] for rows in _owned_rows(engine, user_a).values())
        with Session(engine) as session:
            assert session.exec(select(Identity)).all() == []
            assert session.exec(select(ApiToken).where(ApiToken.user_id == user_a)).all() == []
        for token in (token_a, other_token):
            assert client.get("/me", headers=bearer(token)).status_code == 401
        assert _owned_rows(engine, user_b) == b_before
        assert client.get("/me", headers=bearer(token_b)).json()["email"] == B_EMAIL


def test_personal_tokens_are_listed_without_secrets_and_scoped():  # AC 11
    with _app() as client:
        engine = client.app.state.engine
        user_a, user_b = add_user(engine, A_EMAIL), add_user(engine, B_EMAIL)
        token_a, token_b = token_for(engine, user_a), token_for(engine, user_b)
        with Session(engine) as session:
            stats = auth.mint(session, user_a, TokenKind.pat, TokenScope.stats, name="widget")
            auth.mint(session, user_a, TokenKind.access, TokenScope.deck, client_id="la-carte-ios")
        listed = client.get("/me/tokens", headers=bearer(token_a)).json()
        assert [t["name"] for t in listed] == ["widget", "test"]  # PATs only, newest first
        for item in listed:
            assert set(item) == {"id", "name", "scope", "created_at", "expires_at", "last_used_at"}
        assert token_a not in str(listed) and stats not in str(listed)
        b_id = client.get("/me/tokens", headers=bearer(token_b)).json()[0]["id"]
        assert client.delete(f"/me/tokens/{b_id}", headers=bearer(token_a)).status_code == 404
        assert client.get("/me", headers=bearer(token_b)).status_code == 200
        widget = listed[0]["id"]
        assert client.delete(f"/me/tokens/{widget}", headers=bearer(token_a)).status_code == 204
        assert client.delete(f"/me/tokens/{widget}", headers=bearer(token_a)).status_code == 404
        assert client.get("/stats", headers=bearer(stats)).status_code == 401
        assert [t["name"] for t in client.get("/me/tokens", headers=bearer(token_a)).json()] == [
            "test"
        ]


# --- AC 12: no secrets in the logs --------------------------------------------------------------


def test_no_token_hash_or_email_is_logged(tmp_path, caplog):  # AC 12
    caplog.set_level(logging.DEBUG)
    url = _pre_030_db(tmp_path / "deck.db")
    settings = Settings(
        database_url=url, owner_email=OWNER_EMAIL, api_token="legacy-secret", _env_file=None
    )
    with TestClient(create_app(settings)) as client:
        engine = client.app.state.engine
        user_a = add_user(engine, A_EMAIL)
        token_a = token_for(engine, user_a)
        with Session(engine) as session:
            deck.send_feedback(session, user_a, "hi")
        for token in ("legacy-secret", token_a, "lc_pat_wrong"):
            client.get("/notes", headers=bearer(token))
            client.get("/me", headers=bearer(token))
            _mcp(client, "tools/list", token=token)
            _mcp(client, "tools/call", {"name": "activity_log", "arguments": {"user": A_EMAIL}},
                 token)  # fmt: skip
            _mcp(client, "tools/call", {"name": "list_feedback", "arguments": {}}, token)
        client.delete("/me", headers=bearer(token_a))
    secrets = ["legacy-secret", token_a, "lc_pat_wrong", OWNER_EMAIL, A_EMAIL]
    secrets += [auth.token_hash(s) for s in ("legacy-secret", token_a)]
    assert caplog.text
    for secret in secrets:
        assert secret not in caplog.text


# --- AC 15-16: the owner reads feedback ---------------------------------------------------------


@pytest.fixture
def three_users(engine):
    """Owner O, users A and B (each sent feedback, has activity), C (activity, no feedback)."""
    ids = {}
    with Session(engine) as session:
        for name, email in (("O", OWNER_EMAIL), ("A", A_EMAIL), ("B", B_EMAIL),
                            ("C", "c@example.com")):  # fmt: skip
            ids[name] = add_user(engine, email)
            if name != "C":
                deck.send_feedback(session, ids[name], f"{name}'s feedback")
            deck.ingest_activity(session, ids[name], [_event(kind="app_open"), _event()])
    return ids


async def _feedback(client, status="all") -> list[dict]:
    return (await client.call_tool("list_feedback", {"status": status})).structured_content[
        "result"
    ]


def _not_found(message: str) -> bool:
    """The error for an id that doesn't exist (`deck.NotFound`: "No <thing> with id …")."""
    return re.search(r"No (note|card|report|feedback) with id [0-9a-f-]{36}$", message) is not None


async def _error(client, tool: str, arguments: dict) -> str:
    result = await client.call_tool(tool, arguments)
    assert result.is_error
    return result.content[0].text


@pytest.mark.parametrize("owner_set", [True, False])
async def test_a_non_owner_gets_nothing_cross_user(engine, three_users, owner_set):  # AC 15
    settings = Settings(owner_email=OWNER_EMAIL if owner_set else None, _env_file=None)
    with Session(engine) as session:
        a_feedback = deck.list_feedback(session, three_users["A"], "all")[0]
    callers = ["B"] if owner_set else ["B", "O"]  # unset owner: O behaves exactly like B
    for name in callers:
        async with mcp_client(engine, three_users[name], settings) as client:
            for status in ("open", "done", "all"):
                feedback = await _feedback(client, status)
                assert {f["message"] for f in feedback} <= {f"{name}'s feedback"}
            assert {f["user_email"] for f in await _feedback(client)} == {
                B_EMAIL if name == "B" else OWNER_EMAIL
            }
            assert _not_found(
                await _error(client, "close_feedback", {"feedback_id": str(a_feedback.id)})
            )
            for email in (A_EMAIL, OWNER_EMAIL if name == "B" else B_EMAIL):
                assert "user not found" in await _error(client, "activity_log", {"user": email})
            own = await client.call_tool("activity_log", {"user": B_EMAIL if name == "B" else
                                                          OWNER_EMAIL})  # fmt: skip
            assert len(own.structured_content["result"]) == 2
    with Session(engine) as session:
        assert deck.list_feedback(session, three_users["A"], "all") == [a_feedback]


async def test_the_owner_reads_and_closes_everyones_feedback(engine, three_users):  # AC 16
    settings = Settings(owner_email=OWNER_EMAIL, _env_file=None)
    ids = three_users
    with Session(engine) as session:
        a_feedback = deck.list_feedback(session, ids["A"])[0]
        [a_note] = deck.add_notes(session, ids["A"], [_basic("chat")]).added
        a_card = a_note.cards[0].id
        a_report = deck.report_card(session, ids["A"], a_card, ReportCreate(reason="drop"))[0]
        deck.ingest_activity(session, ids["A"], [_event(a_card, kind="card_rated")])
        a_events = deck.list_activity(session, ids["A"])
    async with mcp_client(engine, ids["O"], settings) as client:
        feedback = await _feedback(client)
        assert {(f["message"], f["user_email"]) for f in feedback} == {
            ("O's feedback", OWNER_EMAIL), ("A's feedback", A_EMAIL), ("B's feedback", B_EMAIL),
        }  # fmt: skip
        closed = await client.call_tool(
            "close_feedback", {"feedback_id": str(a_feedback.id), "note": "fixed in 1.2"}
        )
        assert closed.structured_content["status"] == "done"

        log = (await client.call_tool("activity_log", {"user": A_EMAIL})).structured_content
        assert {e["id"] for e in log["result"]} == {str(e.id) for e in a_events}
        by_card = await client.call_tool("activity_log", {"user": A_EMAIL, "card_id": str(a_card)})
        assert [e["kind"] for e in by_card.structured_content["result"]] == ["card_rated"]
        by_kind = await client.call_tool("activity_log", {"user": A_EMAIL, "kind": "app_open"})
        assert len(by_kind.structured_content["result"]) == 1
        later = (utcnow() + timedelta(minutes=5)).isoformat()
        assert (await client.call_tool("activity_log", {"user": A_EMAIL, "since": later})
                ).structured_content["result"] == []  # fmt: skip
        assert len((await client.call_tool("activity_log", {"user": A_EMAIL, "until": later})
                    ).structured_content["result"]) == 3  # fmt: skip
        for email in ("c@example.com", "nobody@example.com"):
            assert "user not found" in await _error(client, "activity_log", {"user": email})

        assert _not_found(
            await _error(
                client, "update_note", {"note_id": str(a_note.id), "fields": {"back": "x"}}
            )
        )
        assert _not_found(await _error(
            client, "update_report",
            {"report_id": str(a_report.id), "outcome": "kept", "note": "n"},
        ))  # fmt: skip
        assert (await client.call_tool("deck_stats", {})).structured_content["total"] == 0
        assert (await client.call_tool("list_reports", {})).structured_content["result"] == []
    with Session(engine) as session:
        [seen_by_a] = deck.list_feedback(session, ids["A"], "all")
        assert (seen_by_a.status, seen_by_a.resolution) == ("done", "fixed in 1.2")


def test_the_owner_gets_404_on_other_users_rest_data():  # AC 16 (REST)
    with _app(owner_email=OWNER_EMAIL) as client:
        app_engine = client.app.state.engine
        with Session(app_engine) as session:  # created at startup
            owner_id = session.exec(select(User.id).where(User.email == OWNER_EMAIL)).one()
        owner = token_for(app_engine, owner_id)
        a = _fill(client, token_for(app_engine, add_user(app_engine, A_EMAIL)))
        assert client.get(f"/notes/{a['notes'][0]}", headers=bearer(owner)).status_code == 404
        assert client.get(f"/cards/{a['cards'][0]}", headers=bearer(owner)).status_code == 404
        assert client.get("/stats", headers=bearer(owner)).json()["total"] == 0
        assert client.get("/activity", headers=bearer(owner)).json() == []


# --- Activity ingest and retention --------------------------------------------------------------


def test_an_event_id_of_another_user_is_rejected(engine, session):  # decision 3
    user_a, user_b = add_user(engine, A_EMAIL), add_user(engine, B_EMAIL)
    event = _event()
    assert deck.ingest_activity(session, user_a, [event]).stored == 1
    again = deck.ingest_activity(session, user_a, [event])
    assert (again.stored, again.duplicates, again.rejected) == (0, 1, 0)
    other = deck.ingest_activity(session, user_b, [event, _event()])
    assert (other.stored, other.duplicates, other.rejected) == (1, 0, 1)
    assert session.get(ActivityEvent, UUID(event["id"])).user_id == user_a


async def test_activity_is_pruned_daily_while_running(engine, session, monkeypatch):
    user = add_user(engine, A_EMAIL)
    old = _event() | {"at": (utcnow() - timedelta(days=91)).isoformat()}
    deck.ingest_activity(session, user, [old, _event()])
    runs = []
    real = app_module.prune
    monkeypatch.setattr(app_module, "prune", lambda e: runs.append(real(e)))
    task = asyncio.create_task(prune_daily(engine, every=0.01))
    while not runs:
        await asyncio.sleep(0.01)
    task.cancel()
    assert runs[0] == 1
    assert len(deck.list_activity(session, user)) == 1
    assert app_module.PRUNE_EVERY == 24 * 60 * 60
