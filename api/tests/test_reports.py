"""Spec 015a: reporting a card holds it out of study until an agent closes the report."""

import sqlite3
from datetime import timedelta

import pytest
from mcp import Client
from sqlmodel import Session, select

from la_carte_api import deck
from la_carte_api.db import make_engine
from la_carte_api.mcp_server import INSTRUCTIONS, build_mcp
from la_carte_api.models import (
    CardCreate,
    Direction,
    NoteCreate,
    NoteType,
    Rating,
    ReportCreate,
    ReportOutcome,
    ReviewLog,
    utcnow,
)


def _two_way_note(session) -> tuple:
    note = NoteCreate(
        type=NoteType.basic,
        fields={"front": "chat", "back": "cat"},
        directions=[Direction(prompt=["front"]), Direction(prompt=["back"])],
    )
    [added] = deck.add_notes(session, [note], now=utcnow() - timedelta(days=1)).added
    return added.cards[0].id, added.cards[1].id


def _report(session, card_id, reason="wrong"):
    return deck.report_card(session, card_id, ReportCreate(reason=reason))[0]


def _card(session, front="chat", back="cat"):
    return deck.add_cards(session, [CardCreate(front=front, back=back)]).added[0]


# --- REST (#1, #2, #3) -------------------------------------------------------------------------


def test_post_report_returns_the_open_report_with_its_card(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()

    response = client.post(f"/cards/{card['id']}/report", json={"reason": "wrong"})

    assert response.status_code == 201
    report = response.json()
    assert (report["status"], report["reason"], report["comment"]) == ("open", "wrong", None)
    assert (report["card_id"], report["note_id"]) == (card["id"], card["note_id"])
    assert report["card"]["id"] == card["id"]
    assert (report["resolution"], report["resolved_at"]) == (None, None)


@pytest.mark.parametrize(
    "body",
    [
        {"reason": "other"},
        {"reason": "other", "comment": ""},
        {"reason": "other", "comment": "   "},
        {"reason": "wrong", "comment": "x" * 501},
        {"reason": "boring"},
    ],
)
def test_bad_report_is_422(client, body):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    response = client.post(f"/cards/{card['id']}/report", json=body)
    assert response.status_code == 422
    assert "detail" in response.json()


def test_report_unknown_card_is_404_and_comment_is_trimmed(client):
    missing = "00000000-0000-0000-0000-000000000000"
    assert client.post(f"/cards/{missing}/report", json={"reason": "drop"}).status_code == 404
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    report = client.post(
        f"/cards/{card['id']}/report", json={"reason": "other", "comment": " typo "}
    ).json()
    assert report["comment"] == "typo"


def test_reported_card_leaves_study_but_stays_in_the_deck(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    client.post(f"/cards/{card['id']}/report", json={"reason": "drop"})

    assert client.get("/cards/due").json() == []
    stats = client.get("/stats").json()
    assert (stats["total"], stats["due"], stats["next_due"]) == (1, 0, None)
    assert [c["id"] for c in client.get("/cards").json()] == [card["id"]]
    assert len(client.get("/notes").json()) == 1


def test_broken_photo_report_is_idempotent_while_active(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    url = f"/cards/{card['id']}/report"

    first = client.post(url, json={"reason": "broken_photo"})
    again = client.post(url, json={"reason": "broken_photo", "comment": "https://x.test/a.jpg"})

    assert (first.status_code, first.json()["status"]) == (201, "open")
    assert (again.status_code, again.json()["id"]) == (200, first.json()["id"])
    assert client.get("/cards/due").json() == []
    other = client.post(url, json={"reason": "wrong"})
    assert other.status_code == 201
    assert client.post(url, json={"reason": "wrong"}).json()["id"] != other.json()["id"]


def test_broken_photo_reopens_after_its_report_is_fixed(session):
    card = _card(session)
    first = _report(session, card.id, "broken_photo")
    deck.update_report(session, first.id, ReportOutcome.waiting_user, "New URL?")
    assert _report(session, card.id, "broken_photo").id == first.id
    deck.update_report(session, first.id, ReportOutcome.fixed, "Photo replaced")

    second, created = deck.report_card(session, card.id, ReportCreate(reason="broken_photo"))

    assert created and second.id != first.id


def test_held_card_does_not_hide_a_due_sibling(session):
    front, back = _two_way_note(session)
    _report(session, front)
    assert [c.id for c in deck.due_cards(session)] == [back]
    assert deck.stats(session).due == 1


# --- deck: outcomes (#4 - #9) ------------------------------------------------------------------


def test_list_reports_filters_and_orders_oldest_first(session):
    front, back = _two_way_note(session)
    first, second = _report(session, front), _report(session, back, "drop")
    deck.update_report(session, second.id, ReportOutcome.waiting_user, "Drop both directions?")
    closed = _report(session, _card(session, "chien", "dog").id, "doubt")
    deck.update_report(session, closed.id, ReportOutcome.kept, "It is right")

    assert [r.id for r in deck.list_reports(session)] == [first.id, second.id]
    assert [r.id for r in deck.list_reports(session, "all")] == [first.id, second.id, closed.id]
    assert [r.id for r in deck.list_reports(session, "dismissed")] == [closed.id]

    deck.delete_note(session, first.note_id)
    assert [r.card for r in deck.list_reports(session)] == [None, None]


def test_waiting_user_keeps_the_card_held(session):
    front, _ = _two_way_note(session)
    report = _report(session, front, "rephrase")

    updated = deck.update_report(session, report.id, ReportOutcome.waiting_user, " How? ")

    assert (updated.status, updated.resolution, updated.resolved_at) == (
        "waiting_user", "How?", None,
    )  # fmt: skip
    assert front not in [c.id for c in deck.due_cards(session)]


@pytest.mark.parametrize(("outcome", "status"), [("fixed", "resolved"), ("kept", "dismissed")])
def test_fixed_and_kept_bring_the_card_back_unchanged(session, outcome, status):
    card = _card(session)
    deck.review_card(session, card.id, Rating.again, now=utcnow() - timedelta(days=2))
    before = deck.get_card(session, card.id)
    report = _report(session, card.id)

    closed = deck.update_report(session, report.id, ReportOutcome(outcome), "Done")

    assert (closed.status, closed.resolved_at is not None) == (status, True)
    assert deck.get_card(session, card.id) == before
    assert [c.id for c in deck.due_cards(session)] == [card.id]


def test_deleted_removes_that_card_only_and_keeps_history(session):
    front, back = _two_way_note(session)
    deck.review_card(session, front, Rating.good)
    report = _report(session, front, "drop")

    closed = deck.update_report(session, report.id, ReportOutcome.deleted, "Dropped")

    assert (closed.status, closed.card) == ("resolved", None)
    assert [c.id for c in deck.get_note(session, report.note_id).cards] == [back]
    assert session.exec(select(ReviewLog).where(ReviewLog.card_id == front)).all()

    last = _report(session, back, "drop")
    deck.update_report(session, last.id, ReportOutcome.deleted, "Dropped")
    with pytest.raises(deck.NoteNotFound):
        deck.get_note(session, report.note_id)


def test_deleted_on_a_gone_card_just_closes_the_report(session):
    card = _card(session)
    report = _report(session, card.id, "drop")
    deck.delete_card(session, card.id)
    closed = deck.update_report(session, report.id, ReportOutcome.deleted, "Gone")
    assert closed.status == "resolved"


def test_update_report_errors(session):
    card = _card(session)
    report = _report(session, card.id)
    with pytest.raises(deck.ReportNotFound):
        deck.update_report(session, card.id, ReportOutcome.kept, "x")
    with pytest.raises(deck.InvalidReport):
        deck.update_report(session, report.id, ReportOutcome.kept, "  ")
    deck.update_report(session, report.id, ReportOutcome.kept, "Fine")
    with pytest.raises(deck.InvalidReport):
        deck.update_report(session, report.id, ReportOutcome.fixed, "Again")


def test_card_stays_held_until_every_active_report_is_closed(session):
    card = _card(session)
    one, two = _report(session, card.id), _report(session, card.id, "doubt")
    deck.update_report(session, one.id, ReportOutcome.fixed, "Fixed")
    assert deck.due_cards(session) == []
    deck.update_report(session, two.id, ReportOutcome.kept, "Right")
    assert [c.id for c in deck.due_cards(session)] == [card.id]


# --- MCP (#3, #8, #10) -------------------------------------------------------------------------


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.mark.anyio
async def test_agent_works_through_reports(engine):
    with Session(engine) as session:
        card = _card(session, back="kat")
        report = _report(session, card.id)
    async with Client(build_mcp(engine)) as client:
        assert (await client.call_tool("due_cards", {})).structured_content["result"] == []
        [listed] = (await client.call_tool("list_reports", {})).structured_content["result"]
        assert (listed["id"], listed["card"]["back"]) == (str(report.id), "kat")

        for bad in (
            {"report_id": str(report.id), "outcome": "fixed", "note": " "},
            {"report_id": str(report.id), "outcome": "nope", "note": "x"},
            {"report_id": str(card.id), "outcome": "fixed", "note": "x"},
        ):
            assert (await client.call_tool("update_report", bad)).is_error

        done = await client.call_tool(
            "update_report", {"report_id": str(report.id), "outcome": "fixed", "note": "Typo"}
        )
        assert done.structured_content["status"] == "resolved"
        again = await client.call_tool(
            "update_report", {"report_id": str(report.id), "outcome": "kept", "note": "x"}
        )
        assert again.is_error
        assert len((await client.call_tool("due_cards", {})).structured_content["result"]) == 1


def test_instructions_describe_reports():
    assert "Reports. While studying, the user flags cards" in INSTRUCTIONS
    assert "rephrase: ask the user how they want it; change nothing" in INSTRUCTIONS
    assert "broken_photo: the app filed it because a photo failed to load" in INSTRUCTIONS


# --- Migration ---------------------------------------------------------------------------------


def test_report_table_is_added_to_an_existing_database_with_a_backup(tmp_path):
    path = tmp_path / "deck.db"
    url = f"sqlite:///{path}"
    engine = make_engine(url)
    with Session(engine) as session:
        _card(session)
    engine.dispose()
    db = sqlite3.connect(path)
    db.execute("DROP TABLE report")  # as a 014 database
    db.close()

    engine = make_engine(url)

    with Session(engine) as session:
        [card] = deck.list_cards(session)
        assert _report(session, card.id).status == "open"
    engine.dispose()
    assert len(list(tmp_path.glob("deck.db.pre-015-*.bak"))) == 1
    make_engine(url).dispose()  # idempotent: no second backup
    assert len(list(tmp_path.glob("*.bak"))) == 1
