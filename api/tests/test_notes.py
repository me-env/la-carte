"""Spec 014a: notes, directions, sibling burying, and the /cards compatibility layer."""

from datetime import timedelta
from uuid import UUID

import pytest
from mcp import Client
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.mcp_server import build_mcp
from la_carte_api.models import (
    CardCreate,
    Direction,
    NoteCreate,
    NoteType,
    Rating,
    ReviewLog,
    utcnow,
)

pytestmark = pytest.mark.anyio


@pytest.fixture
def anyio_backend():
    return "asyncio"


PHOTO = "https://example.org/p/42.jpg"  # neutral placeholder, never a real person's photo
PERSON = {
    "type": "person",
    "fields": {"photo": PHOTO, "name": "Ada Example", "role": "runs the bakery"},
    "directions": [
        {"prompt": ["photo"], "answer": ["name"]},
        {"prompt": ["role"], "answer": ["name"]},
    ],
}  # fmt: skip
CHAT = {"type": "basic", "fields": {"front": "chat", "back": "cat"}}


def _ways(note: dict) -> list[tuple[list[str], list[str]]]:
    return [(c["prompt"], c["answer"]) for c in note["cards"]]


# --- REST: notes --------------------------------------------------------------------------------


def test_post_person_note_creates_one_card_per_direction(client):
    response = client.post("/notes", json=PERSON)
    assert response.status_code == 201
    note = response.json()
    assert (note["type"], note["fields"]) == ("person", PERSON["fields"])
    assert _ways(note) == [(["photo"], ["name"]), (["role"], ["name"])]
    assert {c["state"] for c in note["cards"]} == {"new"}
    due = {c["id"] for c in client.get("/cards/due").json()}
    assert len(due & {c["id"] for c in note["cards"]}) == 1  # one sibling at a time
    assert client.get(f"/notes/{note['id']}").json() == note


def test_basic_note_without_directions_is_front_to_back_only(client):
    note = client.post("/notes", json=CHAT).json()
    assert _ways(note) == [(["front"], ["back"])]
    assert len(client.get("/cards").json()) == 1


def test_person_without_directions_is_rejected_and_nothing_is_written(client):
    response = client.post("/notes", json={**PERSON, "directions": None})
    assert response.status_code == 422
    assert "Choose directions" in response.json()["detail"]
    assert "photo -> name" in response.json()["detail"]
    assert client.get("/notes").json() == []


def _with(**changes) -> dict:
    return {**PERSON, **changes}


def _fields(**changes) -> dict:
    return {**PERSON["fields"], **changes}


def _directions(*ways: tuple[list[str], list[str]]) -> dict:
    return _with(directions=[{"prompt": p, "answer": a} for p, a in ways])


INVALID = {
    "rule 2, unknown field": (
        _with(fields=_fields(age="40")), ["'age'", "photo, name, role, context"],
    ),
    "rule 3, required field": (_with(fields=_fields(name="  ")), ["'name'"]),
    "rule 4, photo not http": (
        _with(fields=_fields(photo="ftp://example.org/a.jpg")), ["'photo'", "http(s)"],
    ),
    "rule 4, photo no host": (_with(fields=_fields(photo="https:///a.jpg")), ["'photo'"]),
    "rule 5, empty side": (_directions(([], ["name"])), ["(nothing) -> name"]),
    "rule 5, unknown field": (_directions((["age"], ["name"])), ["'age'"]),
    "rule 5, not disjoint": (_directions((["name", "role"], ["name"])), ["'name'", "both"]),
    "rule 5, duplicate": (
        _directions((["name", "photo"], ["role"]), (["photo", "name"], ["role"])),
        ["photo + name -> role", "twice"],
    ),
    "rule 6, field missing": (
        {**_directions((["photo"], ["name"])), "fields": {"name": "Ada"}},
        ["photo -> name", "'photo'"],
    ),
    "rule 7, no directions": (_with(directions=[]), ["at least one direction"]),
    "basic, missing back": ({"type": "basic", "fields": {"front": "chat"}}, ["'back'"]),
}  # fmt: skip


@pytest.mark.parametrize(("body", "expected"), INVALID.values(), ids=INVALID.keys())
def test_validation_rules_are_422_naming_the_field(client, body, expected):
    response = client.post("/notes", json=body)
    assert response.status_code == 422
    detail = response.json()["detail"]
    for text in expected:
        assert text in detail
    assert "example.org" not in detail  # messages name the field, never the value
    assert client.get("/notes").json() == []


@pytest.mark.parametrize(("body", "expected"), INVALID.values(), ids=INVALID.keys())
async def test_validation_rules_are_tool_errors(engine, body, expected):
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool("add_notes", {"notes": [body]})
        assert result.is_error
        for text in expected:
            assert text in result.content[0].text


def test_values_are_trimmed_empty_means_absent_and_directions_are_in_field_order(client):
    fields = {"name": " Ada ", "role": "", "context": "the market", "photo": PHOTO}

    def post(prompt, answer):
        directions = [{"prompt": prompt, "answer": answer}]
        return client.post(
            "/notes", json={"type": "person", "fields": fields, "directions": directions}
        )

    assert post(["photo"], ["role"]).status_code == 422  # "" = absent: no role to recall (rule 6)
    note = post(["name", "photo"], ["context"]).json()
    assert note["fields"] == {"photo": PHOTO, "name": "Ada", "context": "the market"}
    assert _ways(note) == [(["photo", "name"], ["context"])]  # the type's field order


def test_patch_fields_changes_every_sibling_and_keeps_their_schedule(client):
    note = client.post("/notes", json=PERSON).json()
    a, b = (c["id"] for c in note["cards"])
    client.post(f"/cards/{a}/review", json={"rating": "good"})
    before = {i: client.get(f"/cards/{i}").json() for i in (a, b)}

    patched = client.patch(f"/notes/{note['id']}", json={"fields": {"name": "Ada Lovelace"}})

    assert patched.status_code == 200
    assert patched.json()["fields"]["name"] == "Ada Lovelace"
    for i in (a, b):
        card = client.get(f"/cards/{i}").json()
        assert card["fields"]["name"] == "Ada Lovelace"
        assert card["back"] == "Ada Lovelace"
        assert (card["due"], card["state"]) == (before[i]["due"], before[i]["state"])


def test_patch_clearing_a_field_a_direction_uses_says_remove_the_direction_first(client):
    note = client.post("/notes", json=PERSON).json()
    response = client.patch(f"/notes/{note['id']}", json={"fields": {"role": ""}})
    assert response.status_code == 422
    assert "remove the direction first" in response.json()["detail"]
    assert client.get(f"/notes/{note['id']}").json() == note


def test_patch_directions_keeps_adds_and_deletes_cards(client):
    note = client.post("/notes", json=PERSON).json()
    a, b = note["cards"]
    reviewed = client.post(f"/cards/{b['id']}/review", json={"rating": "good"}).json()
    assert reviewed["id"] == b["id"]

    patched = client.patch(
        f"/notes/{note['id']}",
        json={"directions": [{"prompt": ["photo"], "answer": ["name"]},
                             {"prompt": ["name"], "answer": ["photo", "role"]}]},
    ).json()  # fmt: skip

    kept, added = patched["cards"]
    assert (kept["id"], kept["due"]) == (a["id"], a["due"])
    assert (added["prompt"], added["answer"], added["state"]) == (
        ["name"],
        ["photo", "role"],
        "new",
    )
    assert added["id"] not in (a["id"], b["id"])
    assert client.get(f"/cards/{b['id']}").status_code == 404
    with Session(client.app.state.engine) as session:
        logs = session.exec(select(ReviewLog).where(ReviewLog.card_id == UUID(b["id"]))).all()
        assert len(logs) == 1  # history kept


def test_delete_note_removes_its_cards_but_keeps_stats(client):
    note = client.post("/notes", json=PERSON).json()
    client.post(f"/cards/{note['cards'][0]['id']}/review", json={"rating": "good"})
    before = client.get("/stats").json()

    assert client.delete(f"/notes/{note['id']}").status_code == 204

    assert client.get(f"/notes/{note['id']}").status_code == 404
    assert client.get("/cards").json() == client.get("/cards/due").json() == []
    after = client.get("/stats").json()
    assert (after["streak"], after["reviewed_today"]) == (
        before["streak"],
        before["reviewed_today"],
    )
    assert client.delete(f"/notes/{note['id']}").status_code == 404


def test_get_notes_filters_by_query_and_type_and_ignores_photo(client):
    client.post("/notes", json=PERSON)
    client.post("/notes", json={"type": "basic", "fields": {"front": "Bäckerei", "back": "bakery"}})

    def search(**params):
        return [n["type"] for n in client.get("/notes", params=params).json()]

    assert search(query=" BAKERY ") == ["basic", "person"]  # newest first
    assert search(query="bakery", type="person") == ["person"]
    assert search(query="example.org") == []  # photo is not searched
    assert search(limit=1) == ["basic"]
    assert client.get("/notes", params={"limit": 501}).status_code == 422


# --- Burying (deck, injected now) ---------------------------------------------------------------


def _person(session, now):
    [note] = deck.add_notes(session, [NoteCreate.model_validate(PERSON)], now=now).added
    return note


def test_due_queue_serves_one_card_per_note_and_buries_siblings_for_6_hours(session):
    now = utcnow()
    note = _person(session, now - timedelta(minutes=1))
    a, b = note.cards
    assert [c.id for c in deck.due_cards(session, now=now)] == [a.id]  # most overdue, one per note

    assert deck.review_card(session, a.id, Rating.easy, now=now).due > now + timedelta(days=1)

    def due_at(delta):
        return [c.id for c in deck.due_cards(session, now=now + delta)]

    assert due_at(timedelta(hours=5, minutes=59)) == []
    assert due_at(timedelta(hours=6, minutes=1)) == [b.id]


def test_relearning_card_is_served_while_its_sibling_stays_buried(session):
    now = utcnow()
    a, b = _person(session, now).cards
    deck.review_card(session, a.id, Rating.again, now=now)
    again = deck.get_card(session, a.id)
    assert now < again.due < now + timedelta(hours=1)

    assert [c.id for c in deck.due_cards(session, now=again.due)] == [a.id]
    assert b.id not in [c.id for c in deck.due_cards(session, now=again.due)]


def test_burying_never_touches_other_notes(session):
    now = utcnow()
    a, _ = _person(session, now).cards
    [chat] = deck.add_cards(session, [CardCreate(front="chat", back="cat")], now=now).added
    deck.review_card(session, a.id, Rating.easy, now=now)
    assert [c.id for c in deck.due_cards(session, now=now)] == [chat.id]
    deck.review_card(session, chat.id, Rating.again, now=now)  # a one-card note: as before
    relearn = deck.get_card(session, chat.id).due
    assert [c.id for c in deck.due_cards(session, now=relearn)] == [chat.id]


def test_stats_due_matches_the_queue_and_next_due_is_the_end_of_burying(session):
    now = utcnow()
    a, _ = _person(session, now).cards
    assert deck.stats(session, now=now).due == len(deck.due_cards(session, limit=500, now=now)) == 1

    deck.review_card(session, a.id, Rating.easy, now=now)  # A due in days; B buried

    stats = deck.stats(session, now=now + timedelta(minutes=1))
    assert (stats.total, stats.due, stats.new) == (2, 0, 1)
    assert stats.next_due == now + deck.SIBLING_BURY


# --- /cards compatibility -----------------------------------------------------------------------


def test_card_json_carries_note_data_and_joined_front_back(client):
    note = client.post(
        "/notes",
        json={**PERSON, "directions": [{"prompt": ["photo"], "answer": ["name", "role"]}]},
    ).json()
    [card] = client.get("/cards").json()
    assert card["note_id"] == note["id"]
    assert (card["type"], card["prompt"], card["answer"]) == ("person", ["photo"], ["name", "role"])
    assert card["fields"] == PERSON["fields"]
    assert (card["front"], card["back"]) == (PHOTO, "Ada Example\nruns the bakery")

    response = client.patch(f"/cards/{card['id']}", json={"back": "x"})
    assert response.status_code == 422
    assert f"PATCH /notes/{note['id']}" in response.json()["detail"]
    assert client.patch(f"/cards/{card['id']}", json={"front": PHOTO + "?v=2"}).status_code == 200


def test_post_cards_makes_a_basic_note_and_query_matches_the_note(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    note = client.get(f"/notes/{card['note_id']}").json()
    assert (note["type"], note["fields"], _ways(note)) == (
        "basic", {"front": "chat", "back": "cat"}, [(["front"], ["back"])],
    )  # fmt: skip
    assert [c["id"] for c in client.get("/cards", params={"query": "CAT"}).json()] == [card["id"]]


def test_patch_cards_front_on_a_reverse_card_edits_the_note_back(client):
    note = client.post(
        "/notes",
        json={**CHAT, "directions": [{"prompt": ["front"], "answer": ["back"]},
                                     {"prompt": ["back"], "answer": ["front"]}]},
    ).json()  # fmt: skip
    forward, reverse = note["cards"]
    assert reverse["prompt"] == ["back"]

    updated = client.patch(f"/cards/{reverse['id']}", json={"front": "x"}).json()

    assert (updated["front"], updated["back"]) == ("x", "chat")
    assert client.get(f"/notes/{note['id']}").json()["fields"] == {"front": "chat", "back": "x"}
    assert client.get(f"/cards/{forward['id']}").json()["back"] == "x"  # the sibling sees it


def test_delete_cards_removes_a_direction_and_the_note_with_its_last_card(client):
    note = client.post("/notes", json=PERSON).json()
    a, b = (c["id"] for c in note["cards"])

    assert client.delete(f"/cards/{a}").status_code == 204
    assert _ways(client.get(f"/notes/{note['id']}").json()) == [(["role"], ["name"])]

    assert client.delete(f"/cards/{b}").status_code == 204
    assert client.get(f"/notes/{note['id']}").status_code == 404


# --- MCP note tools -----------------------------------------------------------------------------


async def test_add_notes_skips_duplicate_keys_unless_allowed(engine):
    async with Client(build_mcp(engine)) as client:
        first = await client.call_tool("add_notes", {"notes": [CHAT, PERSON]})
        assert not first.is_error
        chat, ada = first.structured_content["added"]

        result = await client.call_tool(
            "add_notes",
            {"notes": [
                {"type": "basic", "fields": {"front": "  CHAT ", "back": "a cat"}},
                {"type": "basic", "fields": {"front": "chien", "back": "dog"}},
                {"type": "basic", "fields": {"front": "Chien", "back": "dog again"}},  # same call
                {"type": "person", "fields": {"name": " ada EXAMPLE", "role": "x"},
                 "directions": [{"prompt": ["role"], "answer": ["name"]}]},
                {"type": "basic", "fields": {"front": "Ada Example", "back": "a person"}},
            ]},
        )  # fmt: skip
        assert not result.is_error, result.content
        added = result.structured_content["added"]
        assert [(n["type"], n["fields"]["front"]) for n in added] == [
            ("basic", "chien"), ("basic", "Ada Example"),  # basic and person keys don't collide
        ]  # fmt: skip
        skipped = result.structured_content["skipped"]
        assert [n["id"] for n in skipped] == [chat["id"], added[0]["id"], ada["id"]]
        assert skipped[0] == chat  # the existing note, as it is

        forced = await client.call_tool("add_notes", {"notes": [CHAT], "allow_duplicates": True})
        assert (len(forced.structured_content["added"]), forced.structured_content["skipped"]) == (
            1, [],
        )  # fmt: skip


async def test_add_notes_is_all_or_nothing_and_names_the_bad_note(engine):
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool(
            "add_notes", {"notes": [CHAT, {**PERSON, "directions": []}]}
        )
        assert result.is_error
        assert "Note 2: A note needs at least one direction" in result.content[0].text
        assert (await client.call_tool("find_notes", {})).structured_content["result"] == []


async def test_note_tools(engine):
    async with Client(build_mcp(engine)) as client:
        [note] = (await client.call_tool("add_notes", {"notes": [PERSON]})).structured_content[
            "added"
        ]

        found = await client.call_tool("find_notes", {"query": "bakery", "type": "person"})
        assert [n["id"] for n in found.structured_content["result"]] == [note["id"]]

        updated = await client.call_tool(
            "update_note", {"note_id": note["id"], "fields": {"context": "the market"}}
        )
        assert updated.structured_content["fields"]["context"] == "the market"

        direction = {"note_id": note["id"], "prompt": ["context"], "answer": ["name"]}
        added = await client.call_tool("add_direction", direction)
        assert _ways(added.structured_content)[-1] == (["context"], ["name"])
        again = await client.call_tool("add_direction", direction)
        assert again.is_error
        assert "already has the direction context -> name" in again.content[0].text

        cards = added.structured_content["cards"]
        for card in cards[:-1]:
            removed = await client.call_tool("remove_direction", {"card_id": card["id"]})
            assert not removed.is_error
        assert len(removed.structured_content["cards"]) == 1
        last = await client.call_tool("remove_direction", {"card_id": cards[-1]["id"]})
        assert last.is_error
        assert "delete_note" in last.content[0].text

        deleted = await client.call_tool("delete_note", {"note_id": note["id"]})
        assert not deleted.is_error
        gone = await client.call_tool("delete_note", {"note_id": note["id"]})
        assert gone.is_error


async def test_due_cards_tool_serves_the_buried_queue(engine):
    with Session(engine) as session:
        a, _ = deck.add_notes(session, [NoteCreate.model_validate(PERSON)]).added[0].cards
    async with Client(build_mcp(engine)) as client:
        [due] = (await client.call_tool("due_cards", {})).structured_content["result"]
        assert due["id"] == str(a.id)
        await client.call_tool("review_card", {"card_id": str(a.id), "rating": "easy"})
        assert (await client.call_tool("due_cards", {})).structured_content["result"] == []
        stats = (await client.call_tool("deck_stats", {})).structured_content
        assert (stats["total"], stats["due"]) == (2, 0)


def test_note_types_table_matches_the_spec():
    assert deck.NOTE_TYPES[NoteType.basic].fields == ("front", "back")
    assert deck.NOTE_TYPES[NoteType.person].fields == ("photo", "name", "role", "context")
    assert deck.SIBLING_BURY == timedelta(hours=6)
    assert Direction(prompt=["a"], answer=["b"]).prompt == ["a"]
