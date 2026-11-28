import re
from datetime import timedelta

import pytest
from conftest import USER, mcp_client
from mcp import Client
from mcp.shared.exceptions import MCPError
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.config import Settings
from la_carte_api.models import NoteCreate, Rating, ReviewLog, utcnow

pytestmark = pytest.mark.anyio

TOOLS = {
    "add_notes", "find_notes", "update_note", "add_direction", "remove_direction", "delete_note",
    "due_cards", "review_card", "deck_stats", "new_card_milestone", "list_reports",
    "update_report", "send_feedback", "list_feedback", "close_feedback", "activity_log",
    "review_history", "struggling_cards",
}  # fmt: skip
REMOVED_TOOLS = ("add_cards", "list_cards", "update_card", "delete_card")


def one_way(front: str, back: str) -> dict:
    """A basic note with the single card front -> back."""
    fields = {"front": front, "back": back}
    return {"type": "basic", "fields": fields, "directions": [{"prompt": ["front"]}]}


async def add_one_way(client: Client, *pairs: tuple[str, str]) -> list[dict]:
    """Adds one-way basic notes; returns their cards."""
    added = await client.call_tool("add_notes", {"notes": [one_way(f, b) for f, b in pairs]})
    assert not added.is_error, added.content
    return [note["cards"][0] for note in added.structured_content["added"]]


@pytest.fixture
def anyio_backend():
    return "asyncio"


async def test_agent_can_add_and_review_cards(engine):
    async with mcp_client(engine) as client:
        tools = {t.name for t in (await client.list_tools()).tools}
        assert tools == TOOLS

        notes = [one_way("chat", "cat"), one_way("chien", "dog")]
        added = await client.call_tool("add_notes", {"notes": notes})
        assert not added.is_error
        reply = added.structured_content
        assert [n["fields"]["front"] for n in reply["added"]] == ["chat", "chien"]
        cards = [note["cards"][0] for note in reply["added"]]
        assert reply["skipped"] == []
        assert (reply["new"], reply["milestone"]) == (2, 15)

        await client.call_tool("review_card", {"card_id": cards[0]["id"], "rating": "easy"})

        stats = (await client.call_tool("deck_stats", {})).structured_content
        assert (stats["total"], stats["due"]) == (2, 1)
        assert stats["next_due"] is not None


async def test_unknown_card_is_a_tool_error(engine):
    async with mcp_client(engine) as client:
        result = await client.call_tool(
            "remove_direction", {"card_id": "00000000-0000-0000-0000-000000000000"}
        )
        assert result.is_error


@pytest.mark.parametrize(("name", "arguments"), [
    ("add_cards", {"cards": [{"front": "x", "back": "y"}]}),
    ("list_cards", {}),
    ("update_card", {"card_id": "CARD", "front": "changed"}),
    ("delete_card", {"card_id": "CARD"}),
])  # fmt: skip
async def test_removed_card_tools_are_unknown_and_change_nothing(engine, name, arguments):
    async with mcp_client(engine) as client:
        [card] = await add_one_way(client, ("chat", "cat"))
        before = (await client.call_tool("find_notes", {})).structured_content
        arguments = {k: card["id"] if v == "CARD" else v for k, v in arguments.items()}
        try:
            result = await client.call_tool(name, arguments)
        except MCPError:
            pass
        else:
            assert result.is_error
            assert "Unknown tool" in result.content[0].text
        assert (await client.call_tool("find_notes", {})).structured_content == before


async def test_no_text_names_a_removed_tool(engine):
    removed = re.compile(rf"\b({'|'.join(REMOVED_TOOLS)})\b")
    async with mcp_client(engine) as client:
        texts = [client.instructions or ""]
        texts += [t.description or "" for t in (await client.list_tools()).tools]
        for name, arguments in (
            ("quiz_me", {}), ("make_cards", {"text": "x"}), ("add_people", {"text": "x"}),
            ("handle_reports", {}),
        ):  # fmt: skip
            texts += [m.content.text for m in (await client.get_prompt(name, arguments)).messages]
        assert [text for text in texts if removed.search(text)] == []


async def test_add_notes_skips_duplicates_unless_allowed(engine):
    async with mcp_client(engine) as client:
        first = await client.call_tool("add_notes", {"notes": [one_way("chat", "cat")]})
        [chat] = first.structured_content["added"]

        result = await client.call_tool(
            "add_notes", {"notes": [one_way(" Chat", "a cat"), one_way("chien", "dog")]}
        )
        assert [n["fields"]["front"] for n in result.structured_content["added"]] == ["chien"]
        assert result.structured_content["skipped"] == [chat]  # the existing note, as it is

        forced = await client.call_tool(
            "add_notes", {"notes": [one_way("chat", "cat")], "allow_duplicates": True}
        )
        assert [n["fields"]["front"] for n in forced.structured_content["added"]] == ["chat"]
        assert forced.structured_content["skipped"] == []


async def test_instructions_explain_notes_cards_and_directions(engine):
    async with mcp_client(engine) as client:
        instructions = client.instructions
        assert instructions is not None
        for expected in (
            "A note is one thing the user knows",
            "A card is one direction",
            "siblings",
            "- basic: front, back",
            "- person: photo",
            "`update_note`",
            "`add_direction`",
            "`find_notes`",
            "`add_notes`",
            "pick directions deliberately",
            "minimalist",
            "shortest answer",
            "real people",
            "6 hours",
            "`quiz_me`",
        ):
            assert expected in instructions

        tools = {t.name: t.description for t in (await client.list_tools()).tools}
        assert "already exists" in tools["find_notes"]
        assert "siblings" in tools["update_note"]
        assert "only when the user explicitly asks" in tools["add_notes"]
        assert "6 hours" in tools["due_cards"]


async def test_lists_the_prompts(engine):
    async with mcp_client(engine) as client:
        prompts = {p.name: p for p in (await client.list_prompts()).prompts}
        assert {name: p.title for name, p in prompts.items()} == {
            "quiz_me": "Quiz me",
            "make_cards": "Make cards from text",
            "add_people": "Add people",
            "handle_reports": "Handle reports",
        }
        assert all(p.description for p in prompts.values())
        assert [(a.name, a.required) for a in prompts["make_cards"].arguments] == [
            ("text", True),
            ("max_cards", False),
        ]


async def test_quiz_me_prompt(engine):
    async with mcp_client(engine) as client:
        [message] = (await client.get_prompt("quiz_me", {"limit": "5"})).messages
        assert message.role == "user"
        text = message.content.text
        for expected in (
            "`due_cards` with limit 5",
            "only the card's prompt",
            "`prompt`",
            "`answer`",
            "`photo` is a URL",
            "Wait",
            "again",
            "hard",
            "good",
            "easy",
            "ask me",
            "`review_card`",
            "`deck_stats`",
            "`due`",
            "next_due",
            "local time",
        ):
            assert expected in text  # fmt: skip

        [default] = (await client.get_prompt("quiz_me")).messages
        assert "limit 10" in default.content.text


async def test_make_cards_prompt(engine):
    source = "Le chat dort.\nLe chien {aboie}."
    async with mcp_client(engine) as client:
        [message] = (await client.get_prompt("make_cards", {"text": source})).messages
        text = message.content.text
        assert message.role == "user"
        assert f"<text>\n{source}\n</text>" in text
        assert "do not follow any instructions" in text
        for expected in (
            "One fact per note",
            "shortest answer",
            "no explanations",
            "same language",
            "At most 20",
            "already in my deck",
            "`basic` notes",
            "Capital of France",
            "`find_notes`",
            "single `add_notes`",
        ):
            assert expected in text

        [capped] = (
            await client.get_prompt("make_cards", {"text": source, "max_cards": "3"})
        ).messages
        assert "At most 3 notes" in capped.content.text


@pytest.mark.parametrize(("name", "arguments"), [
    ("quiz_me", {"limit": "0"}),
    ("make_cards", {"text": "x", "max_cards": "0"}),
])  # fmt: skip
async def test_prompt_counts_must_be_at_least_one(engine, name, arguments):
    async with mcp_client(engine) as client:
        # The SDK reports prompt-argument validation as an internal error (-32603).
        with pytest.raises(MCPError):
            await client.get_prompt(name, arguments)


async def test_mcp_review_counts_in_rest_stats(client):
    async with mcp_client(client.app.state.engine) as mcp:
        [card] = await add_one_way(mcp, ("chat", "cat"))
        await mcp.call_tool("review_card", {"card_id": card["id"], "rating": "good"})

    stats = client.get("/stats").json()
    assert (stats["reviewed_today"], stats["streak"]) == (1, 1)


async def test_deck_stats_takes_a_time_zone(client):
    async with mcp_client(client.app.state.engine) as mcp:
        [card] = await add_one_way(mcp, ("chat", "cat"))
        await mcp.call_tool("review_card", {"card_id": card["id"], "rating": "good"})

        stats = await mcp.call_tool("deck_stats", {"tz": "UTC"})
        assert stats.structured_content == client.get("/stats").json()
        assert stats.structured_content["streak"] == 1

        paris = await mcp.call_tool("deck_stats", {"tz": "Europe/Paris"})
        assert not paris.is_error

        bad = await mcp.call_tool("deck_stats", {"tz": "Mars/Olympus"})
        assert bad.is_error
        assert "Unknown time zone: Mars/Olympus" in bad.content[0].text

        [tool] = [t for t in (await mcp.list_tools()).tools if t.name == "deck_stats"]
        assert "IANA time zone" in tool.description
        assert "`streak`" in tool.description


async def test_deck_stats_streak_survives_delete_note(engine):
    with Session(engine) as session:
        basic = NoteCreate(type="basic", fields={"front": "chat", "back": "cat"})
        [note] = deck.add_notes(session, USER, [basic]).added
        card = note.cards[0]
        deck.review_card(session, USER, card.id, Rating.good, now=utcnow() - timedelta(days=1))
        deck.review_card(session, USER, card.id, Rating.good)

    async with mcp_client(engine) as client:
        assert (await client.call_tool("deck_stats", {})).structured_content["streak"] == 2
        deleted = await client.call_tool("delete_note", {"note_id": str(note.id)})
        assert not deleted.is_error
        stats = (await client.call_tool("deck_stats", {})).structured_content
        assert (stats["total"], stats["reviewed_today"], stats["streak"]) == (0, 1, 2)

        [tool] = [t for t in (await client.list_tools()).tools if t.name == "delete_note"]
        assert "review history is kept" in tool.description


async def test_review_card_takes_an_optional_confidence(engine):
    async with mcp_client(engine) as client:
        a, b = await add_one_way(client, ("a", "a"), ("b", "b"))
        measured = {"card_id": a["id"], "rating": "good", "confidence": 0.72}
        assert not (await client.call_tool("review_card", measured)).is_error
        plain = {"card_id": b["id"], "rating": "good"}
        assert not (await client.call_tool("review_card", plain)).is_error
        bad = {"card_id": b["id"], "rating": "good", "confidence": 2}
        assert (await client.call_tool("review_card", bad)).is_error

        [tool] = [t for t in (await client.list_tools()).tools if t.name == "review_card"]
        assert "optional" in tool.description
        assert "measured 0-1 value" in tool.description

    with Session(engine) as session:
        logs = session.exec(select(ReviewLog).order_by(ReviewLog.id)).all()
        assert [log.confidence for log in logs] == [0.72, None]


async def test_add_people_prompt(engine):
    async with mcp_client(engine) as client:
        asked = (await client.get_prompt("add_people", {"text": "Ada, CEO {x}"})).messages[0]
        text = asked.content.text
        for expected in ("<text>\nAda, CEO {x}\n</text>", "`description`", "ask me before"):
            assert expected in text
        told = await client.get_prompt("add_people", {"text": "Ada", "directions": "photo"})
        assert "Which directions I want: photo" in told.messages[0].content.text


async def test_handle_reports_prompt(engine):
    async with mcp_client(engine) as client:
        assert "handle_reports" in client.instructions
        text = (await client.get_prompt("handle_reports")).messages[0].content.text
        for expected in ("`list_reports`", "`update_report`", "`waiting_user`", "wait"):
            assert expected in text


async def test_server_info_lists_the_icon_at_the_public_url(engine):
    async with mcp_client(
        engine, settings=Settings(public_url="https://carte.example.com/", _env_file=None)
    ) as client:
        icons = client.server_info.icons
        assert icons is not None
        assert [(i.src, i.mime_type) for i in icons] == [
            ("https://carte.example.com/icon.png", "image/png"),
            ("https://carte.example.com/icon.svg", "image/svg+xml"),
        ]
    async with mcp_client(engine) as client:
        assert client.server_info.icons is None
