from fastapi.testclient import TestClient

from la_carte_api.app import create_app
from la_carte_api.config import Settings


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
    assert stats == {
        "total": 1, "due": 0, "new": 0, "reviewed_today": 1, "next_due": reviewed["due"],
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
