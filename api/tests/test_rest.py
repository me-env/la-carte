from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session, select

from la_carte_api.app import create_app
from la_carte_api.config import Settings
from la_carte_api.models import ReviewLog


def test_card_lifecycle(client):
    created = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    assert created["state"] == "new"

    assert [c["id"] for c in client.get("/cards/due").json()] == [created["id"]]

    reviewed = client.post(f"/cards/{created['id']}/review", json={"rating": "good"}).json()
    assert reviewed["state"] == "learning"
    assert client.get("/cards/due").json() == []

    updated = client.patch(f"/cards/{created['id']}", json={"back": "a cat"}).json()
    assert updated["back"] == "a cat"

    stats = client.get("/stats").json()
    today = datetime.now(UTC).date().isoformat()
    assert stats == {
        "total": 1, "due": 0, "new": 0, "reviewed_today": 1, "next_due": reviewed["due"],
        "new_today": 1, "milestone": 15, "streak": 1, "streak_start": today,
        "history_start": today, "history": "s", "due_new": 0,
        "at_risk_total": 0, "at_risk_done": 0, "reviews_total": 0, "reviews_done": 0,
    }  # fmt: skip

    assert client.delete(f"/cards/{created['id']}").status_code == 204
    assert client.get(f"/cards/{created['id']}").status_code == 404


def test_stats_next_due_is_null_for_an_empty_deck(client):
    assert client.get("/stats").json()["next_due"] is None


def test_post_cards_always_adds_even_a_duplicate(client):
    client.post("/cards", json={"front": "chat", "back": "cat"})
    assert client.post("/cards", json={"front": "Chat", "back": "cat"}).status_code == 201
    assert len(client.get("/cards").json()) == 2


def test_rejects_empty_card(client):
    assert client.post("/cards", json={"front": "", "back": "x"}).status_code == 422


def test_bearer_token_is_required_when_configured():
    app = create_app(Settings(database_url="sqlite://", api_token="secret", _env_file=None))
    with TestClient(app) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/cards").status_code == 401
        assert client.post("/mcp", json={}).status_code == 401
        assert client.get("/cards", headers={"Authorization": "Bearer secret"}).status_code == 200


def test_stats_rejects_an_unknown_time_zone(client):
    response = client.get("/stats", params={"tz": "Mars/Olympus"})
    assert response.status_code == 422
    assert response.json() == {"detail": "Unknown time zone: Mars/Olympus"}
    assert client.get("/stats", params={"tz": "../etc/passwd"}).status_code == 422


def test_stats_without_tz_is_utc(client):
    created = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    client.post(f"/cards/{created['id']}/review", json={"rating": "good"})

    default = client.get("/stats").json()
    assert default == client.get("/stats", params={"tz": "UTC"}).json()
    assert (default["reviewed_today"], default["streak"]) == (1, 1)
    assert client.get("/stats", params={"tz": "Europe/Paris"}).status_code == 200


def test_deleting_a_card_keeps_stats(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    client.post(f"/cards/{card['id']}/review", json={"rating": "good"})
    before = client.get("/stats").json()

    assert client.delete(f"/cards/{card['id']}").status_code == 204

    assert client.get("/cards").json() == []
    assert client.get("/cards/due").json() == []
    after = client.get("/stats").json()
    assert (after["reviewed_today"], after["streak"]) == (1, before["streak"]) == (1, 1)


# --- spec 013: confidence ----------------------------------------------------------------------


def _logs(client) -> list[tuple[str, float | None]]:
    with Session(client.app.state.engine) as session:
        return [(log.rating, log.confidence) for log in session.exec(select(ReviewLog))]


def test_review_stores_an_optional_confidence(client):
    a, b = (client.post("/cards", json={"front": f, "back": f}).json() for f in ("a", "b"))

    with_confidence = client.post(
        f"/cards/{a['id']}/review", json={"rating": "good", "confidence": 0.72}
    )
    without = client.post(f"/cards/{b['id']}/review", json={"rating": "good"})

    assert (with_confidence.status_code, without.status_code) == (200, 200)
    assert _logs(client) == [("good", 0.72), ("good", None)]


def test_review_rejects_a_confidence_outside_0_1(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    for confidence in (-0.01, 1.01):
        response = client.post(
            f"/cards/{card['id']}/review", json={"rating": "good", "confidence": confidence}
        )
        assert response.status_code == 422
    assert client.get(f"/cards/{card['id']}").json() == card  # not rescheduled
    assert _logs(client) == []


@pytest.mark.parametrize(
    ("path", "media_type"),
    [
        ("/favicon.ico", "image/x-icon"),
        ("/icon.png", "image/png"),
        ("/apple-touch-icon.png", "image/png"),
        ("/icon.svg", "image/svg+xml"),
    ],
)
def test_icons_are_served_without_the_token(path, media_type):
    app = create_app(Settings(database_url="sqlite://", api_token="secret", _env_file=None))
    with TestClient(app) as client:
        response = client.get(path)
        assert response.status_code == 200
        assert response.headers["content-type"].startswith(media_type)
        assert "max-age" in response.headers["cache-control"]
        assert response.content
