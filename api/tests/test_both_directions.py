"""Spec 026: basic notes without `directions` get both cards (front -> back, back -> front)."""

from datetime import UTC, datetime

import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import Direction, NoteCreate, NoteType, NoteUpdate

pytestmark = pytest.mark.anyio

CHAT = {"type": "basic", "fields": {"front": "chat", "back": "cat"}}
BOTH = [(["front"], ["back"]), (["back"], ["front"])]
PERSON = {"type": "person", "fields": {"name": "Ada Example", "description": "runs the bakery"}}


@pytest.fixture
def anyio_backend():
    return "asyncio"


def _ways(note: dict) -> list[tuple[list[str], list[str]]]:
    return [(c["prompt"], c["answer"]) for c in note["cards"]]


async def _tools(engine) -> dict[str, str]:
    async with Client(build_mcp(engine)) as client:
        return {t.name: t.description for t in (await client.list_tools()).tools}


async def test_ac1_mcp_add_notes_basic_without_directions_makes_both_cards(engine):
    before = datetime.now(UTC)
    async with Client(build_mcp(engine)) as client:
        reply = (await client.call_tool("add_notes", {"notes": [CHAT]})).structured_content
    [note] = reply["added"]
    assert _ways(note) == BOTH
    for card in note["cards"]:
        assert card["state"] == "new"
        assert before <= datetime.fromisoformat(card["due"]) <= datetime.now(UTC)


def test_ac2_rest_post_notes_basic_without_directions_makes_both_cards(client):
    response = client.post("/notes", json=CHAT)
    assert response.status_code == 201
    assert _ways(response.json()) == BOTH
    assert all(c["state"] == "new" for c in response.json()["cards"])


async def test_ac3_explicit_single_direction_makes_one_card(engine):
    one = {**CHAT, "directions": [{"prompt": ["front"], "answer": ["back"]}]}
    async with Client(build_mcp(engine)) as client:
        [note] = (await client.call_tool("add_notes", {"notes": [one]})).structured_content["added"]
        notes = (await client.call_tool("find_notes", {})).structured_content["result"]
    assert _ways(note) == [(["front"], ["back"])]
    assert [len(n["cards"]) for n in notes] == [1]


async def test_ac4_person_without_directions_still_fails_mcp(engine):
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool("add_notes", {"notes": [PERSON]})
        assert result.is_error
        assert "photo -> name + description" in result.content[0].text
        notes = await client.call_tool("find_notes", {})
    assert notes.structured_content["result"] == []


def test_ac4_person_without_directions_still_fails_rest(client):
    response = client.post("/notes", json=PERSON)
    assert response.status_code == 422
    assert "photo -> name + description" in response.json()["detail"]
    assert client.get("/notes").json() == []


def test_ac5_rest_post_cards_makes_one_card(client):
    response = client.post("/cards", json={"front": "chat", "back": "cat"})
    assert response.is_success
    [note] = client.get("/notes").json()
    assert _ways(note) == [(["front"], ["back"])]
    assert len(client.get("/cards").json()) == 1


async def test_ac6_add_notes_new_counts_both_cards(engine):
    async with Client(build_mcp(engine)) as client:
        reply = (await client.call_tool("add_notes", {"notes": [CHAT]})).structured_content
    assert reply["new"] == 2


def test_ac7_update_note_fields_does_not_backfill_reverse_card(session: Session):
    one_way = NoteCreate(
        type=NoteType.basic,
        fields={"front": "chat", "back": "cat"},
        directions=[Direction(prompt=["front"], answer=["back"])],
    )
    [note] = deck.add_notes(session, [one_way]).added
    updated = deck.update_note(session, note.id, NoteUpdate(fields={"back": "a cat"}))
    assert [(c.prompt, c.answer) for c in updated.cards] == [(["front"], ["back"])]


def test_ac8_instructions_state_the_both_directions_default():
    [basic_line] = [line for line in INSTRUCTIONS.splitlines() if line.startswith("- basic:")]
    assert "back -> front" in basic_line
    assert "Capital of France" in INSTRUCTIONS
    assert 'never "all of them"' not in INSTRUCTIONS
    assert "Default direction: front -> back" not in INSTRUCTIONS


async def test_ac9_make_cards_prompt_and_add_notes_description(engine):
    async with Client(build_mcp(engine)) as client:
        [message] = (await client.get_prompt("make_cards", {"text": "x"})).messages
    assert "never add every direction by default" not in message.content.text
    assert "Capital of France" in message.content.text
    add_notes = (await _tools(engine))["add_notes"]
    assert "back -> front" in add_notes
    assert "front -> back only" not in add_notes


def test_ac11_openapi_note_create_directions_says_basic_defaults_to_both(client):
    schema = client.get("/openapi.json").json()["components"]["schemas"]["NoteCreate"]
    description = schema["properties"]["directions"]["description"]
    assert "basic (both: front -> back and back -> front" in description
