"""Spec 025: agents send feedback to the developer who runs the server (MCP only)."""

import sqlite3
from datetime import timedelta

import pytest
from mcp import Client
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import CardCreate, Feedback, FeedbackKind, ReportCreate, utcnow

pytestmark = pytest.mark.anyio
MISSING = "00000000-0000-0000-0000-000000000000"


@pytest.fixture
def anyio_backend():
    return "asyncio"


def _rows(engine) -> list[Feedback]:
    with Session(engine) as session:
        return list(session.exec(select(Feedback)))


async def _send(client, **arguments) -> dict:
    result = await client.call_tool("send_feedback", arguments)
    assert not result.is_error, result.content
    return result.structured_content


async def _list(client, **arguments) -> list[dict]:
    return (await client.call_tool("list_feedback", arguments)).structured_content["result"]


async def test_send_feedback_returns_and_stores_it(engine):  # 1
    async with Client(build_mcp(engine)) as client:
        sent = await _send(client, message="add_notes should accept tags")

    assert set(sent) == {
        "id", "kind", "message", "status", "resolution", "created_at", "closed_at"
    }  # fmt: skip
    assert (sent["kind"], sent["message"], sent["status"]) == (
        "other", "add_notes should accept tags", "open",
    )  # fmt: skip
    assert (sent["resolution"], sent["closed_at"]) == (None, None)
    assert sent["created_at"]
    [row] = _rows(engine)
    assert (str(row.id), row.message) == (sent["id"], "add_notes should accept tags")


async def test_message_is_trimmed(engine):  # 2
    async with Client(build_mcp(engine)) as client:
        assert (await _send(client, message="  slow  "))["message"] == "slow"
    assert [row.message for row in _rows(engine)] == ["slow"]


async def test_every_kind_is_accepted(engine):  # 3
    async with Client(build_mcp(engine)) as client:
        for kind in FeedbackKind:
            assert (await _send(client, message="x", kind=kind.value))["kind"] == kind.value
    assert sorted(row.kind for row in _rows(engine)) == sorted(FeedbackKind)


@pytest.mark.parametrize("message", ["", "   \n "])
async def test_blank_message_is_an_error_naming_message(engine, message):  # 4
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool("send_feedback", {"message": message})
    assert result.is_error
    assert "`message` is required" in result.content[0].text
    assert _rows(engine) == []


async def test_message_is_at_most_2000_characters(engine):  # 5
    async with Client(build_mcp(engine)) as client:
        too_long = await client.call_tool("send_feedback", {"message": "x" * 2001})
        assert too_long.is_error
        assert "at most 2000 characters" in too_long.content[0].text
        assert len((await _send(client, message=f"  {'x' * 2000}  "))["message"]) == 2000
    assert len(_rows(engine)) == 1


async def test_unknown_kind_is_rejected(engine):  # 6
    async with Client(build_mcp(engine)) as client:
        result = await client.call_tool("send_feedback", {"message": "x", "kind": "praise"})
    assert result.is_error
    assert _rows(engine) == []


async def test_list_filters_by_status_oldest_first(engine):  # 7, 8
    now = utcnow()
    with Session(engine) as session:  # sent out of order: the list sorts by created_at
        late = deck.send_feedback(session, "late", now=now)
        early = deck.send_feedback(session, "early", now=now - timedelta(hours=2))
        closed = deck.send_feedback(session, "closed", now=now - timedelta(hours=1))
        deck.close_feedback(session, closed.id)

    async with Client(build_mcp(engine)) as client:
        assert [f["message"] for f in await _list(client)] == ["early", "late"]
        assert [f["message"] for f in await _list(client, status="open")] == ["early", "late"]
        assert [f["message"] for f in await _list(client, status="done")] == ["closed"]
        all_ = await _list(client, status="all")
        assert [f["message"] for f in all_] == ["early", "closed", "late"]
        assert (await client.call_tool("list_feedback", {"status": "closed"})).is_error
    assert {early.id, late.id} < {row.id for row in _rows(engine)}


async def test_close_with_a_note(engine):  # 9
    async with Client(build_mcp(engine)) as client:
        sent = await _send(client, message="photo field is confusing")
        closed = await client.call_tool(
            "close_feedback", {"feedback_id": sent["id"], "note": "  fixed in 1.2 "}
        )
        assert not closed.is_error
        done = closed.structured_content
        assert (done["status"], done["resolution"]) == ("done", "fixed in 1.2")
        assert done["closed_at"] is not None
        assert await _list(client) == []
        assert [f["id"] for f in await _list(client, status="done")] == [sent["id"]]


@pytest.mark.parametrize("note", [{}, {"note": None}, {"note": "   "}])
async def test_close_without_a_note_has_no_resolution(engine, note):  # 10
    async with Client(build_mcp(engine)) as client:
        sent = await _send(client, message="slow")
        closed = await client.call_tool("close_feedback", {"feedback_id": sent["id"], **note})
        assert (closed.structured_content["status"], closed.structured_content["resolution"]) == (
            "done", None,
        )  # fmt: skip


async def test_close_unknown_or_done_is_an_error_and_changes_nothing(engine):  # 11
    async with Client(build_mcp(engine)) as client:
        unknown = await client.call_tool("close_feedback", {"feedback_id": MISSING})
        assert unknown.is_error
        assert unknown.content[0].text.endswith(f"No feedback with id {MISSING}")

        sent = await _send(client, message="slow")
        await client.call_tool("close_feedback", {"feedback_id": sent["id"], "note": "first"})
        [before] = _rows(engine)
        again = await client.call_tool(
            "close_feedback", {"feedback_id": sent["id"], "note": "second"}
        )
        assert again.is_error
        assert again.content[0].text.endswith(f"Feedback {sent['id']} is already done.")
    [after] = _rows(engine)
    assert after.model_dump() == before.model_dump()


async def test_feedback_never_changes_the_deck(engine):  # 12
    with Session(engine) as session:
        cards = deck.add_cards(
            session, [CardCreate(front="chat", back="cat"), CardCreate(front="chien", back="dog")]
        ).added
        deck.report_card(session, cards[0].id, ReportCreate(reason="wrong"))

    async def snapshot(client) -> list:
        return [
            (await client.call_tool(tool, {})).structured_content
            for tool in ("find_notes", "list_reports", "due_cards", "deck_stats")
        ]

    async with Client(build_mcp(engine)) as client:
        before = await snapshot(client)
        sent = await _send(client, message="due_cards is slow", kind="friction")
        await client.call_tool("close_feedback", {"feedback_id": sent["id"]})
        assert await snapshot(client) == before


def test_startup_adds_the_table_to_a_pre_025_database(tmp_path):  # 13
    path = tmp_path / "deck.db"
    engine = make_engine(f"sqlite:///{path}")
    with Session(engine) as session:
        deck.add_cards(session, [CardCreate(front="chat", back="cat")])
    engine.dispose()
    db = sqlite3.connect(path)
    with db:
        db.execute("DROP TABLE feedback")  # the database as it was before spec 025
    tables = {
        name: db.execute(f"SELECT * FROM {name}").fetchall()
        for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    db.close()
    assert "feedback" not in tables

    make_engine(f"sqlite:///{path}").dispose()

    db = sqlite3.connect(path)
    for name, rows in tables.items():
        assert db.execute(f"SELECT * FROM {name}").fetchall() == rows
    assert db.execute("SELECT count(*) FROM feedback").fetchone() == (0,)
    db.close()
    assert [p.name for p in tmp_path.iterdir()] == ["deck.db"]  # no backup


async def test_instructions_and_description_point_card_content_to_reports(engine):  # 14
    assert (
        "Feedback. Bugs, confusing tools or errors, missing capabilities and friction go to the "
        "developer\nwith `send_feedback` (when the user asks, or on your own when a tool gets in "
        "your way). Card content\ngoes through the app's card reports, not here."
    ) in INSTRUCTIONS
    async with Client(build_mcp(engine)) as client:
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}
    assert "card reports" in tools["send_feedback"].description


def test_no_rest_route_for_feedback(client):  # 15
    assert client.get("/feedback").status_code == 404
    assert client.post("/feedback", json={"message": "x"}).status_code == 404
