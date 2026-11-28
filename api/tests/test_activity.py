"""Spec 029: the app's activity log (POST /activity, GET /activity, MCP `activity_log`)."""

import sqlite3
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from conftest import USER, mcp_client
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.app import create_app
from la_carte_api.config import Settings
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import INSTRUCTIONS
from la_carte_api.models import ActivityEvent, CardCreate, ReportCreate

SESSION = str(uuid4())


@pytest.fixture
def anyio_backend():
    return "asyncio"


def _event(**changes) -> dict:
    event = {
        "id": str(uuid4()),
        "kind": "rated",
        "at": "2026-11-25T10:14:03.120+01:00",
        "tz": "Europe/Paris",
        "session": SESSION,
        "app_version": "1.0",
        "build": "42",
        "os": "iOS 26.1",
        "card_id": str(uuid4()),
        "data": {"rating": "good", "input": "drag", "ms_to_reveal": 1830, "ms_to_rate": 2410},
    }
    return event | changes


def _post(client, events: list[dict]):
    return client.post("/activity", json={"events": events})


def _rows(client) -> list[ActivityEvent]:
    with Session(client.app.state.engine) as session:
        return list(session.exec(select(ActivityEvent)))


# --- Ingest ------------------------------------------------------------------------------------


def test_post_stores_valid_events_in_utc_with_receipt_time(client):  # 1
    events = [_event(), _event(kind="card_shown", card_id=None, data={})]
    before = datetime.now(UTC)

    response = _post(client, events)

    assert response.status_code == 200
    assert response.json() == {"stored": 2, "duplicates": 0, "rejected": 0}
    rows = {str(row.id): row for row in _rows(client)}
    assert set(rows) == {e["id"] for e in events}
    first = rows[events[0]["id"]]
    assert first.at == datetime(2026, 11, 25, 9, 14, 3, 120000, tzinfo=UTC)
    assert before <= first.received_at <= datetime.now(UTC)
    assert first.data["ms_to_rate"] == 2410
    assert rows[events[1]["id"]].card_id is None


def test_posting_the_same_batch_again_is_idempotent(client):  # 2
    events = [_event(), _event()]
    _post(client, events)

    response = _post(client, events)

    assert response.json() == {"stored": 0, "duplicates": 2, "rejected": 0}
    assert len(_rows(client)) == 2


def test_a_repeated_id_within_one_batch_is_stored_once(client):
    event = _event()
    assert _post(client, [event, event]).json() == {"stored": 1, "duplicates": 1, "rejected": 0}


def test_counts_come_from_the_rows_really_inserted(session):  # 2
    stored, new = _event(), _event()
    deck.ingest_activity(session, USER, [stored])  # e.g. a concurrent retry got there first

    result = deck.ingest_activity(session, USER, [stored, new, new, _event(kind="Bad")])

    assert result.model_dump() == {"stored": 1, "duplicates": 2, "rejected": 1}
    assert len(deck.list_activity(session, USER)) == 2


@pytest.mark.parametrize(
    "invalid",
    [
        _event(kind="Rated!"),
        _event(at="2026-11-25T10:14:03.120"),  # naive
        _event(data={"x": "a" * 4097}),
        {k: v for k, v in _event().items() if k != "id"},
        _event(tz="Mars/Olympus"),
        _event(data=[1, 2]),
        "not an object",
    ],
)
def test_an_invalid_event_is_rejected_alone(client, invalid):  # 3
    valid = _event()

    response = _post(client, [invalid, valid])

    assert response.status_code == 200
    assert response.json() == {"stored": 1, "duplicates": 0, "rejected": 1}
    assert [str(row.id) for row in _rows(client)] == [valid["id"]]


def test_an_unknown_well_formed_kind_is_stored(client):  # 4
    event = _event(kind="future_thing")
    assert _post(client, [event]).json()["stored"] == 1
    assert [row.kind for row in _rows(client)] == ["future_thing"]


def test_more_than_500_events_is_413_and_stores_nothing(client):  # 5
    response = _post(client, [_event() for _ in range(501)])

    assert response.status_code == 413
    assert response.json() == {"detail": "At most 500 events per request."}
    assert _rows(client) == []
    assert _post(client, [_event() for _ in range(500)]).json()["stored"] == 500


def test_events_must_be_a_list(client):
    assert client.post("/activity", json={"events": {"id": "x"}}).status_code == 422


def test_activity_needs_the_bearer_token():  # 5
    settings = Settings(
        database_url="sqlite://",
        api_token="secret",
        owner_email="owner@example.com",
        _env_file=None,
    )
    with TestClient(create_app(settings)) as client:
        assert _post(client, [_event()]).status_code == 401
        assert client.get("/activity").status_code == 401
        headers = {"Authorization": "Bearer secret"}
        response = client.post("/activity", json={"events": [_event()]}, headers=headers)
        assert response.json()["stored"] == 1


def test_posting_activity_changes_nothing_in_the_deck(client):  # 10
    with Session(client.app.state.engine) as session:
        cards = deck.add_cards(
            session,
            USER,
            [CardCreate(front="chat", back="cat"), CardCreate(front="chien", back="dog")],
        ).added
        client.post(f"/cards/{cards[1].id}/review", json={"rating": "good"})
        deck.report_card(session, USER, cards[0].id, ReportCreate(reason="wrong"))

    def snapshot() -> list:
        with Session(client.app.state.engine) as session:
            reports = [r.model_dump() for r in deck.list_reports(session, USER, "all")]
            reviews = deck.stats(session, USER).model_dump()
        paths = ("/cards", "/notes", "/cards/due", "/stats")
        return [client.get(path).json() for path in paths] + [reports, reviews]

    before = snapshot()
    _post(client, [_event(card_id=str(cards[0].id)), _event(kind="note_deleted")])
    assert snapshot() == before


# --- Reading -----------------------------------------------------------------------------------


@pytest.fixture
def stored(client) -> dict[str, dict]:
    """Five events a minute apart (UTC 09:00-09:04), two sessions, one card."""
    card, other_session = str(uuid4()), str(uuid4())
    events = {
        "a": _event(at="2026-11-25T10:00:00.000+01:00", kind="app_foreground", card_id=None),
        "b": _event(at="2026-11-25T10:01:00.000+01:00", kind="card_shown", card_id=card),
        "c": _event(at="2026-11-25T10:02:00.000+01:00", kind="rated", card_id=card),
        "d": _event(at="2026-11-25T04:03:00.000-05:00", tz="America/New_York", card_id=None),
        "e": _event(at="2026-11-25T09:04:00.000Z", tz="UTC", session=other_session),
    }
    _post(client, list(events.values()))
    return events


def _ids(events: list[dict]) -> list[str]:
    return [event["id"] for event in events]


def test_get_lists_newest_first_and_filters(client, stored):  # 6
    def get(**params) -> list[str]:
        response = client.get("/activity", params=params)
        assert response.status_code == 200, response.text
        return _ids(response.json())

    a, b, c, d, e = (stored[k]["id"] for k in "abcde")
    assert get() == [e, d, c, b, a]
    assert get(since="2026-11-25T09:01:00Z", until="2026-11-25T09:03:00Z") == [c, b]
    assert get(since="2026-11-25T10:03:00+01:00") == [e, d]  # since is inclusive
    assert get(until="2026-11-25T09:01:00") == [a]  # naive = UTC; until is exclusive
    assert get(card_id=stored["b"]["card_id"]) == [c, b]
    assert get(kind="app_foreground") == [a]
    assert get(session=stored["e"]["session"]) == [e]
    assert get(limit=2) == [e, d]


def test_limit_defaults_to_100_and_is_at_most_1000(client):  # 6
    _post(client, [_event() for _ in range(101)])
    assert len(client.get("/activity").json()) == 100
    assert len(client.get("/activity", params={"limit": 1000}).json()) == 101
    assert client.get("/activity", params={"limit": 1001}).status_code == 422
    assert client.get("/activity", params={"limit": 0}).status_code == 422


def test_each_event_has_local_at_in_its_own_zone(client, stored):  # 7
    events = {e["id"]: e for e in client.get("/activity").json()}

    paris = events[stored["b"]["id"]]
    assert set(paris) == {
        "id", "kind", "at", "local_at", "tz", "session", "card_id", "app_version", "build",
        "os", "data", "received_at",
    }  # fmt: skip
    assert datetime.fromisoformat(paris["at"]) == datetime(2026, 11, 25, 9, 1, tzinfo=UTC)
    assert paris["local_at"].startswith("2026-11-25T10:01:00") and paris["local_at"].endswith(
        "+01:00"
    )
    new_york = events[stored["d"]["id"]]["local_at"]
    assert new_york.startswith("2026-11-25T04:03:00") and new_york.endswith("-05:00")


@pytest.mark.anyio
async def test_mcp_activity_log_returns_the_same_list(client, stored):  # 6
    async with mcp_client(client.app.state.engine) as mcp:
        result = await mcp.call_tool("activity_log", {"card_id": stored["b"]["card_id"]})
        everything = await mcp.call_tool("activity_log", {})
        too_many = await mcp.call_tool("activity_log", {"limit": 1001})

    rest = client.get("/activity", params={"card_id": stored["b"]["card_id"]}).json()
    assert result.structured_content["result"] == rest
    assert _ids(everything.structured_content["result"]) == _ids(client.get("/activity").json())
    assert too_many.is_error


# --- Startup -----------------------------------------------------------------------------------


def test_startup_prunes_events_older_than_90_days(tmp_path):  # 8
    url = f"sqlite:///{tmp_path / 'deck.db'}"
    engine = make_engine(url)
    now = datetime.now(UTC)
    old = _event(at=(now - timedelta(days=91)).isoformat())
    recent = _event(at=(now - timedelta(days=89)).isoformat())
    with Session(engine) as session:
        [card] = deck.add_cards(session, USER, [CardCreate(front="chat", back="cat")]).added
        deck.ingest_activity(session, USER, [old, recent])
    engine.dispose()

    create_app(Settings(database_url=url, _env_file=None)).state.engine.dispose()

    db = sqlite3.connect(tmp_path / "deck.db")
    ids = [row[0] for row in db.execute("SELECT id FROM activityevent")]
    assert ids == [recent["id"].replace("-", "")]
    assert db.execute("SELECT count(*) FROM card").fetchone() == (1,)
    db.close()


def test_prune_activity_uses_the_retention_cutoff(session):  # 8
    now = datetime(2026, 11, 25, tzinfo=UTC)
    events = [
        _event(at=(now - deck.ACTIVITY_RETENTION - timedelta(seconds=1)).isoformat()),
        _event(at=(now - deck.ACTIVITY_RETENTION).isoformat()),
    ]
    deck.ingest_activity(session, USER, events)

    assert deck.prune_activity(session, now=now) == 1
    assert _ids([e.model_dump(mode="json") for e in deck.list_activity(session, USER)]) == [
        events[1]["id"]
    ]


def test_startup_adds_the_table_to_a_pre_029_database(tmp_path):  # 9
    path = tmp_path / "deck.db"
    engine = make_engine(f"sqlite:///{path}")
    with Session(engine) as session:
        deck.add_cards(session, USER, [CardCreate(front="chat", back="cat")])
    engine.dispose()
    db = sqlite3.connect(path)
    with db:
        db.execute("DROP TABLE activityevent")  # the database as it was before spec 029
    tables = {
        name: db.execute(f"SELECT * FROM {name}").fetchall()
        for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    db.close()

    create_app(Settings(database_url=f"sqlite:///{path}", _env_file=None)).state.engine.dispose()

    db = sqlite3.connect(path)
    for name, rows in tables.items():
        assert db.execute(f"SELECT * FROM {name}").fetchall() == rows
    assert db.execute("SELECT count(*) FROM activityevent").fetchone() == (0,)
    indexed = {row[1] for row in db.execute("PRAGMA index_list(activityevent)")}
    assert {"ix_activityevent_at", "ix_activityevent_card_id", "ix_activityevent_kind"} <= indexed
    db.close()
    assert [p.name for p in tmp_path.iterdir()] == ["deck.db"]  # no backup


# --- Pointers for agents -----------------------------------------------------------------------


@pytest.mark.anyio
async def test_feedback_and_reports_point_to_activity_log(engine):  # 11
    assert (
        "Activity. `activity_log` lists what the user did in the app (dated); read it when "
        "handling feedback or reports. It holds no card text."
    ) in " ".join(INSTRUCTIONS.split())
    async with mcp_client(engine) as client:
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}
    assert "`activity_log` around each item's `created_at`" in tools["list_feedback"].description
    assert "`activity_log(card_id=…)`" in tools["list_reports"].description
    assert "Read-only; kept 90 days" in " ".join(tools["activity_log"].description.split())
