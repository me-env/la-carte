"""Spec 024 step 1: `/stats` history, freezes, `streak_start`, `due_new` (+ 021's `new_today`,
`milestone`)."""

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest
from mcp import Client
from sqlmodel import Session

from la_carte_api import deck
from la_carte_api.mcp_server import build_mcp
from la_carte_api.models import CardCreate, Rating, ReportCreate, ReviewLog, Settings, utcnow

PARIS = ZoneInfo("Europe/Paris")
NOON = datetime(2026, 11, 21, 12, 0, tzinfo=UTC)
DAY = timedelta(days=1)


def _days(first: date, last: date) -> list[date]:
    return [first + i * DAY for i in range((last - first).days + 1)]


def _log(session: Session, days: list[date], tz=UTC, at=time(10)) -> None:
    """One review per day at `at` local time (no card needed: `ReviewLog` outlives cards)."""
    card_id = deck.add_cards(session, [CardCreate(front="chat", back="cat")]).added[0].id
    for day in days:
        when = datetime.combine(day, at, tzinfo=tz).astimezone(UTC)
        session.add(ReviewLog(card_id=card_id, rating=Rating.good, reviewed_at=when))
    session.commit()


# --- AC 1: the history alphabet ------------------------------------------------------------------


def test_no_reviews_is_a_single_pending_day(session):
    stats = deck.stats(session, now=NOON)
    assert (stats.history, stats.history_start, stats.streak_start) == ("p", NOON.date(), None)


def test_history_runs_from_the_first_review_day_to_today(session):
    today = NOON.date()
    _log(session, [today - 5 * DAY, today - 2 * DAY, today - DAY, today])
    stats = deck.stats(session, now=NOON)
    # 4 days ago: the day before is studied, but 3 days ago isn't, so it's missed
    assert (stats.history_start, stats.history) == (today - 5 * DAY, "smmsss")
    assert len(stats.history) == (today - stats.history_start).days + 1


def test_pending_is_only_the_last_letter_when_today_has_no_review(session):
    _log(session, [NOON.date() - 3 * DAY])
    assert deck.stats(session, now=NOON).history == "smmp"


# --- AC 3: the chronological freeze --------------------------------------------------------------


def test_a_freeze_is_spent_when_the_day_is_missed_so_the_later_miss_breaks(session):
    today = NOON.date()
    studied = [today - d * DAY for d in (10, 8, 7, 6, 5, 3, 2, 1, 0)]
    _log(session, studied)
    stats = deck.stats(session, now=NOON)
    assert stats.history == "sfssssmssss"  # f at D-9, m at D-4
    assert (stats.streak, stats.streak_start) == (4, today - 3 * DAY)


def test_two_missed_days_in_a_row_are_both_missed(session):
    today = NOON.date()
    _log(session, [today - d * DAY for d in (5, 2, 1, 0)])
    stats = deck.stats(session, now=NOON)
    assert stats.history == "smmsss"
    assert (stats.streak, stats.streak_start) == (3, today - 2 * DAY)


def test_a_provisionally_frozen_yesterday_breaks_once_today_ends_unstudied(session):
    today = NOON.date()
    _log(session, [today - 2 * DAY])
    assert deck.stats(session, now=NOON).history == "sfp"
    tomorrow = deck.stats(session, now=NOON + DAY)
    assert (tomorrow.history, tomorrow.streak) == ("smmp", 0)


# --- AC 4: the scenario fixtures (today = Sun 2026-11-22, Paris) ---------------------------------


def _d(text: str) -> date:
    return date.fromisoformat(text if len(text) == 10 else f"2026-{text}")


def _span(*ranges: str) -> set[date]:
    days: set[date] = set()
    for r in ranges:
        first, _, last = r.partition("..")
        days.update(_days(_d(first), _d(last or first)))
    return days


SCENARIOS = {  # id: (studied, streak, streak_start, frozen days)
    "zero": (set(), 0, None, set()),
    "three": (_span("11-20..11-22"), 3, "11-20", set()),
    "nine": (_span("11-13..11-21"), 9, "11-13", set()),
    "freezes": (
        _span("10-26", "10-29..11-22") - _span("11-05", "11-16"),
        25,
        "10-29",
        _span("11-05", "11-16"),
    ),
    "broken": (_span("11-08..11-17", "11-20..11-22"), 3, "11-20", set()),
    "lone": (_span("10-30..11-14", "11-17", "11-20..11-22"), 3, "11-20", set()),
    "sixty": (_span("09-01..09-21", "09-24..11-22"), 60, "09-24", set()),
    "sixtyFrozen": (
        _span("09-01..09-21", "09-24..11-22") - _span("11-20"),
        60,
        "09-24",
        _span("11-20"),
    ),
    "twoHundred": (_span("03-01..05-03", "05-06..11-21"), 200, "05-06", set()),
    "eightHundred": (
        _span("2024-06-01..2024-09-10", "2024-09-13..2026-11-21"),
        800,
        "2024-09-13",
        set(),
    ),
}


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_scenario(session, scenario):
    studied, streak, start, frozen = SCENARIOS[scenario]
    today = date(2026, 11, 22)
    _log(session, sorted(studied), tz=PARIS)

    stats = deck.stats(session, now=datetime(2026, 11, 22, 12, tzinfo=PARIS), tz=PARIS)

    assert (stats.streak, stats.streak_start) == (streak, start and _d(start))
    first = min(studied, default=today)
    expected = "".join(
        "s" if d in studied else "f" if d in frozen else "m" for d in _days(first, today)
    )
    if today not in studied:
        expected = expected[:-1] + "p"
    assert (stats.history_start, stats.history) == (first, expected)


# --- AC 6: due_new; spec 021's new_today and milestone -------------------------------------------


def test_due_new_counts_the_servable_never_reviewed_cards(session):
    now = utcnow()
    cards = deck.add_cards(
        session, [CardCreate(front=f"w{i}", back="x") for i in range(5)], now=now - 30 * DAY
    ).added
    for card in cards[3:]:
        deck.review_card(session, card.id, Rating.again, now=now - 30 * DAY)  # due long ago
    deck.report_card(session, cards[0].id, ReportCreate(reason="broken_photo"))  # held out

    stats = deck.stats(session, now=now)
    assert (stats.due, stats.due_new) == (4, 2)


def test_new_today_counts_cards_first_reviewed_today_in_the_local_day(session):
    now = datetime(2026, 11, 22, 12, tzinfo=PARIS)
    late, early, deleted = deck.add_cards(
        session, [CardCreate(front=w, back="x") for w in ("a", "b", "c")], now=now - 2 * DAY
    ).added
    for card, first in (
        (late, datetime(2026, 11, 21, 23, 30, tzinfo=PARIS)),  # yesterday: doesn't count
        (early, datetime(2026, 11, 22, 0, 10, tzinfo=PARIS)),
        (deleted, datetime(2026, 11, 22, 9, 0, tzinfo=PARIS)),
    ):
        deck.review_card(session, card.id, Rating.again, now=first.astimezone(UTC))
    deck.review_card(session, late.id, Rating.good, now=now.astimezone(UTC) - timedelta(hours=1))
    deck.delete_card(session, deleted.id)

    assert deck.stats(session, now=now, tz=PARIS).new_today == 2
    assert deck.stats(session, now=now, tz=UTC).new_today == 1  # 00:10 Paris is yesterday in UTC


def test_milestone_is_the_stored_size_and_15_for_none_or_zero(session):
    assert deck.stats(session).milestone == 15
    deck.set_milestone(session, 5)
    assert deck.stats(session).milestone == 5
    session.merge(Settings(new_cards_per_day=0))
    session.commit()
    assert deck.stats(session).milestone == 15


# --- AC 1 over REST, AC 7 over MCP ---------------------------------------------------------------


def test_rest_stats_serves_the_new_fields_as_json(client):
    card = client.post("/cards", json={"front": "chat", "back": "cat"}).json()
    assert client.post(f"/cards/{card['id']}/review", json={"rating": "good"}).is_success

    stats = client.get("/stats", params={"tz": "Europe/Paris"}).json()
    today = datetime.now(PARIS).date().isoformat()
    assert stats["history"] == "s"
    assert (stats["history_start"], stats["streak_start"], stats["streak"]) == (today, today, 1)
    assert (stats["new_today"], stats["milestone"], stats["due_new"]) == (1, 15, 0)


@pytest.mark.anyio
async def test_mcp_deck_stats_has_the_fields_and_explains_freezes(client):
    async with Client(build_mcp(client.app.state.engine)) as mcp:
        stats = (await mcp.call_tool("deck_stats", {"tz": "Europe/Paris"})).structured_content
        rest = client.get("/stats", params={"tz": "Europe/Paris"}).json()
        assert stats == rest
        assert (stats["history"], stats["streak_start"]) == ("p", None)

        [tool] = [t for t in (await mcp.list_tools()).tools if t.name == "deck_stats"]
        assert "forgives one missed day per 7" in tool.description
        assert "s studied, f frozen, m missed, p today not yet studied" in tool.description
