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
    "fields": {"photo": PHOTO, "name": "Ada Example", "description": "runs the bakery"},
    "directions": [
        {"prompt": ["photo"], "answer": ["name", "description"]},
        {"prompt": ["description"]},
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
    assert _ways(note) == [
        (["photo"], ["name", "description"]),
        (["description"], ["photo", "name"]),
    ]
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
    assert "photo -> name + description" in response.json()["detail"]
    assert client.get("/notes").json() == []


def _with(**changes) -> dict:
    return {**PERSON, **changes}


def _fields(**changes) -> dict:
    return {**PERSON["fields"], **changes}


def _directions(*ways: tuple[list[str], list[str]]) -> dict:
    return _with(directions=[{"prompt": p, "answer": a} for p, a in ways])  # a None: omitted


INVALID = {
    "rule 2, unknown field": (
        _with(fields=_fields(age="40")), ["'age'", "photo, name, description"],
    ),
    "removed field role": (_with(fields=_fields(role="CEO")), ["'role'", "use description"]),
    "removed field context": (
        _directions((["context"], None)), ["'context'", "use description"],
    ),
    "rule 3, required field": (_with(fields=_fields(name="  ")), ["'name'"]),
    "rule 4, photo not http": (
        _with(fields=_fields(photo="ftp://example.org/a.jpg")), ["'photo'", "http(s)"],
    ),
    "rule 4, photo no host": (_with(fields=_fields(photo="https:///a.jpg")), ["'photo'"]),
    "rule 5, empty prompt": (_directions(([], ["name"])), ["(nothing) -> name", "one field"]),
    "rule 5, two prompts": (_directions((["photo", "name"], None)), ["one field"]),
    "rule 5, unknown field": (_directions((["age"], ["name"])), ["'age'"]),
    "rule 5, partial answer": (
        _directions((["photo"], ["name"])), ["every other field", "photo -> name + description"],
    ),
    "rule 5, duplicate": (
        _directions((["name"], None), (["name"], ["photo", "description"])),
        ["name -> photo + description", "twice"],
    ),
    "rule 6, field missing": (
        {**_directions((["photo"], None)), "fields": {"name": "Ada"}},
        ["photo -> name + description", "'photo'"],
    ),
    "rule 6, nothing to recall": (
        {**_directions((["name"], None)), "fields": {"name": "Ada"}},
        ["nothing to recall"],
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


def test_values_are_trimmed_empty_means_absent_and_empty_answer_fields_are_left_out(client):
    fields = {"name": " Ada ", "description": "", "photo": PHOTO}

    def post(prompt, answer=None):
        directions = [{"prompt": prompt, "answer": answer}]
        return client.post(
            "/notes", json={"type": "person", "fields": fields, "directions": directions}
        )

    assert post(["description"]).status_code == 422  # "" = absent: no prompt (rule 6)
    note = post(["name"], ["photo"]).json()  # the set fields only: accepted
    assert note["fields"] == {"photo": PHOTO, "name": "Ada"}
    assert _ways(note) == [(["name"], ["photo"])]  # no description: left out
    [card] = client.get("/cards").json()
    assert (card["answer"], card["back"]) == (["photo"], PHOTO)

    patched = client.patch(f"/notes/{note['id']}", json={"fields": {"description": "CEO"}})
    assert _ways(patched.json()) == [(["name"], ["photo", "description"])]  # shows up when set


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
        assert "Ada Lovelace" in card["back"].split("\n")
        assert (card["due"], card["state"]) == (before[i]["due"], before[i]["state"])


def test_patch_clearing_a_field_a_direction_uses_says_remove_the_direction_first(client):
    note = client.post("/notes", json=PERSON).json()
    response = client.patch(f"/notes/{note['id']}", json={"fields": {"description": ""}})
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
        json={"directions": [{"prompt": ["photo"], "answer": ["name", "description"]},
                             {"prompt": ["name"]}]},
    ).json()  # fmt: skip

    kept, added = patched["cards"]
    assert (kept["id"], kept["due"]) == (a["id"], a["due"])
    assert (added["prompt"], added["answer"], added["state"]) == (
        ["name"],
        ["photo", "description"],
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
    assert [c.id for c in deck.due_cards(session, now=now)] == [a.id]  # oldest first, one per note

    assert deck.review_card(session, a.id, Rating.easy, now=now).due > now + timedelta(days=1)

    def due_at(delta):
        return [c.id for c in deck.due_cards(session, now=now + delta)]

    assert due_at(timedelta(hours=5, minutes=59)) == []
    assert due_at(timedelta(hours=6, minutes=1)) == [b.id]


def test_a_card_rated_again_frees_its_sibling_and_wins_at_its_due(session):
    now = utcnow()
    a, b = _person(session, now - timedelta(minutes=1)).cards
    again = deck.review_card(session, a.id, Rating.again, now=now).due
    assert now < again < now + deck.SIBLING_BURY

    def due_at(t):
        return [c.id for c in deck.due_cards(session, now=t)]

    assert due_at(again - timedelta(seconds=1)) == []  # B held until A is due again
    assert due_at(again) == [a.id]  # both due, one per note: the (re)learning card wins
    deck.review_card(session, a.id, Rating.easy, now=again)
    assert due_at(again) == []  # B held again: siblings never back to back
    assert due_at(again + deck.SIBLING_BURY) == [b.id]


def test_a_failed_card_comes_back_at_its_due_even_after_a_sibling_was_answered(session):
    now = utcnow()
    a, b = _person(session, now - timedelta(minutes=1)).cards
    step = deck.review_card(session, b.id, Rating.good, now=now).due
    assert deck.review_card(session, b.id, Rating.good, now=step).state == "review"

    failed = step + timedelta(minutes=1)
    again = deck.review_card(session, a.id, Rating.again, now=failed).due
    answered = deck.review_card(session, b.id, Rating.good, now=failed + timedelta(seconds=30))
    assert answered.state == "review" and answered.due > again + deck.SIBLING_BURY

    assert [c.id for c in deck.due_cards(session, now=again)] == [a.id]  # B's 6 h hold skips A
    stats = deck.stats(session, now=again - timedelta(seconds=1))
    assert (stats.due, stats.next_due) == (0, again)


def _three_ways(session, now):
    ways = _directions(
        (["photo"], ["name", "description"]), (["description"], None), (["name"], None)
    )
    [note] = deck.add_notes(session, [NoteCreate.model_validate(ways)], now=now).added
    return note.cards


def test_a_hold_follows_the_reviewed_cards_latest_review_and_every_sibling_holds(session):
    now = utcnow()
    a, b, c = _three_ways(session, now - timedelta(minutes=1))
    deck.review_card(session, a.id, Rating.again, now=now)
    later = now + timedelta(minutes=1)
    deck.review_card(session, a.id, Rating.easy, now=later)  # A's latest review: due in days

    def due_at(t):
        return [x.id for x in deck.due_cards(session, now=t)]

    assert due_at(later + deck.SIBLING_BURY - timedelta(seconds=1)) == []
    assert due_at(later + deck.SIBLING_BURY) == [b.id]

    relearn = deck.review_card(session, b.id, Rating.again, now=later).due
    assert relearn < later + deck.SIBLING_BURY
    assert due_at(relearn) == [b.id]  # B learning: never held; C still held by A (6 h)
    assert due_at(later + deck.SIBLING_BURY) == [b.id]  # C free too, but B (learning) wins


def test_a_card_rated_good_with_a_long_interval_holds_its_sibling_6_hours(session):
    now = utcnow()
    a, b = _person(session, now - timedelta(minutes=1)).cards
    step = deck.review_card(session, a.id, Rating.good, now=now).due  # learning step
    later = step + timedelta(minutes=1)
    due = deck.review_card(session, a.id, Rating.good, now=later).due  # graduates: days
    assert due > later + deck.SIBLING_BURY

    assert deck.due_cards(session, now=later + deck.SIBLING_BURY - timedelta(seconds=1)) == []
    assert [x.id for x in deck.due_cards(session, now=later + deck.SIBLING_BURY)] == [b.id]


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


def test_stats_next_due_is_the_failed_siblings_due_and_matches_the_queue(session):
    now = utcnow()
    a, b = _person(session, now - timedelta(minutes=1)).cards
    again = deck.review_card(session, a.id, Rating.again, now=now).due

    stats = deck.stats(session, now=now + timedelta(seconds=1))
    assert (stats.due, stats.next_due) == (0, again)  # B freed when A is due, not in 6 h
    at_due = deck.stats(session, now=again)
    assert at_due.due == len(deck.due_cards(session, limit=500, now=again)) == 1


# --- /cards compatibility -----------------------------------------------------------------------


def test_card_json_carries_note_data_and_joined_front_back(client):
    note = client.post(
        "/notes",
        json={**PERSON, "directions": [{"prompt": ["photo"]}]},
    ).json()
    [card] = client.get("/cards").json()
    assert card["note_id"] == note["id"]
    assert (card["type"], card["prompt"], card["answer"]) == (
        "person",
        ["photo"],
        ["name", "description"],
    )
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
    assert _ways(client.get(f"/notes/{note['id']}").json()) == [
        (["description"], ["photo", "name"])
    ]

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
                {"type": "person", "fields": {"name": " ada EXAMPLE", "description": "x"},
                 "directions": [{"prompt": ["description"]}]},
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
            "update_note", {"note_id": note["id"], "fields": {"description": "the market"}}
        )
        assert updated.structured_content["fields"]["description"] == "the market"

        direction = {"note_id": note["id"], "prompt": ["name"]}
        added = await client.call_tool("add_direction", direction)
        assert _ways(added.structured_content)[-1] == (["name"], ["photo", "description"])
        again = await client.call_tool("add_direction", {**direction, "answer": ["description"]})
        assert again.is_error  # a partial answer is refused
        assert "every other field" in again.content[0].text
        again = await client.call_tool("add_direction", direction)
        assert again.is_error
        assert "already has the direction name -> photo + description" in again.content[0].text

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
    assert deck.NOTE_TYPES[NoteType.person].fields == ("photo", "name", "description")
    assert deck.SIBLING_BURY == timedelta(hours=6)
    assert Direction(prompt=["a"]).answer is None
