import re
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from sqlmodel import col, select

from la_carte_api import deck
from la_carte_api.models import CardCreate, CardState, Rating, ReviewLog, utcnow


def test_new_cards_are_due_immediately(session):
    [card] = deck.add_cards(session, [CardCreate(front="chat", back="cat")]).added
    assert card.state is CardState.new
    assert deck.due_cards(session) == [card]


def test_good_review_schedules_card_in_the_future(session):
    now = utcnow()
    [card] = deck.add_cards(session, [CardCreate(front="chat", back="cat")], now=now).added

    reviewed = deck.review_card(session, card.id, Rating.good, now=now)

    assert reviewed.due > now
    assert reviewed.state is not CardState.new
    assert deck.due_cards(session, now=now) == []


def test_easy_is_scheduled_later_than_again(session):
    now = utcnow()
    again, easy = deck.add_cards(
        session, [CardCreate(front="a", back="a"), CardCreate(front="b", back="b")], now=now
    ).added
    assert (
        deck.review_card(session, easy.id, Rating.easy, now=now).due
        > deck.review_card(session, again.id, Rating.again, now=now).due
    )


def test_stats(session):
    now = utcnow()
    first, _ = deck.add_cards(
        session, [CardCreate(front="a", back="a"), CardCreate(front="b", back="b")], now=now
    ).added
    deck.review_card(session, first.id, Rating.easy, now=now)

    stats = deck.stats(session, now=now + timedelta(seconds=1))

    assert (stats.total, stats.due, stats.new, stats.reviewed_today) == (2, 1, 1, 1)


def test_search_matches_front_and_back(session):
    deck.add_cards(
        session, [CardCreate(front="chien", back="dog"), CardCreate(front="chat", back="cat")]
    )
    assert [c.front for c in deck.list_cards(session, query="DOG")] == ["chien"]


def test_search_is_casefolded_trimmed_and_literal(session):
    now = utcnow()
    fronts = ["Été", "50% off", "a_b", "axb", "Straße"]
    for i, front in enumerate(fronts):  # distinct created_at so newest-first is deterministic
        deck.add_cards(session, [CardCreate(front=front, back="x")], now=now + timedelta(seconds=i))

    def search(query, limit=100):
        return [c.front for c in deck.list_cards(session, query=query, limit=limit)]

    assert search("été") == search("ÉTÉ") == search("  été ") == ["Été"]
    assert search("STRASSE") == ["Straße"]  # casefold, not just lower
    assert search("%") == ["50% off"]
    assert search("a_b") == ["a_b"]
    assert search("   ") == search(None) == list(reversed(fronts))
    assert search("b", limit=1) == ["axb"]  # limit applies after filtering, newest first


def test_next_due_is_the_earliest_due_strictly_after_now(session):
    now = utcnow()
    new_cards = [CardCreate(front=f, back=f) for f in ("a", "b", "c")]
    soon, later, _due_now = deck.add_cards(session, new_cards, now=now).added
    soon = deck.review_card(session, soon.id, Rating.again, now=now)
    later = deck.review_card(session, later.id, Rating.easy, now=now)
    assert now < soon.due < later.due

    assert deck.stats(session, now=now).next_due == soon.due
    assert deck.stats(session, now=soon.due).next_due == later.due  # strictly after now
    assert deck.stats(session, now=later.due).next_due is None


def test_next_due_is_none_for_an_empty_deck(session):
    assert deck.stats(session).next_due is None


def test_add_cards_skips_duplicate_fronts(session):
    [chat] = deck.add_cards(session, [CardCreate(front="Chat", back="cat")]).added

    result = deck.add_cards(
        session,
        [
            CardCreate(front="  CHAT ", back="a cat"),
            CardCreate(front="Straße", back="street"),
            CardCreate(front="STRASSE", back="street again"),  # casefold matches "Straße"
            CardCreate(front="chien", back="dog"),
        ],
        skip_duplicates=True,
    )

    [strasse, chien] = result.added
    assert (strasse.front, chien.front) == ("Straße", "chien")
    assert [c.id for c in result.skipped] == [chat.id, strasse.id]  # first wins
    assert len(deck.list_cards(session)) == 3


def test_add_cards_adds_duplicates_by_default(session):
    deck.add_cards(session, [CardCreate(front="chat", back="cat")])
    result = deck.add_cards(session, [CardCreate(front="chat", back="cat")])
    assert (len(result.added), result.skipped) == (1, [])
    assert len(deck.list_cards(session)) == 2


# --- streak + time zone (spec 007) -------------------------------------------------------------

NOON = datetime(2026, 11, 21, 12, 0, tzinfo=UTC)
PARIS, LOS_ANGELES = ZoneInfo("Europe/Paris"), ZoneInfo("America/Los_Angeles")


def _review_at(session, *times: datetime) -> None:
    [card] = deck.add_cards(session, [CardCreate(front="chat", back="cat")], now=min(times)).added
    for t in sorted(times):
        deck.review_card(session, card.id, Rating.good, now=t.astimezone(UTC))


@pytest.mark.parametrize(
    ("days_ago", "streak"),
    [
        ([], 0),
        ([0], 1),
        ([0, 1, 2], 3),
        ([1, 2], 2),  # none today yet: still alive
        ([2], 0),
        ([0, 1, 3], 2),  # the gap stops it
        ([0, 0, 0], 1),  # several reviews on one day count once
    ],
)
def test_streak_in_utc(session, days_ago, streak):
    if days_ago:
        _review_at(session, *(NOON - timedelta(days=d, hours=1) for d in days_ago))
    assert deck.stats(session, now=NOON).streak == streak


def test_streak_ignores_reviews_after_today(session):
    _review_at(session, NOON + timedelta(days=1))
    assert deck.stats(session, now=NOON).streak == 0


def test_time_zone_with_a_positive_offset(session):
    _review_at(session, datetime(2026, 11, 20, 23, 30, tzinfo=UTC))  # 00:30 on the 21st in Paris
    now = datetime(2026, 11, 21, 7, 0, tzinfo=UTC)

    paris = deck.stats(session, now=now, tz=PARIS)
    assert (paris.reviewed_today, paris.streak) == (1, 1)
    utc = deck.stats(session, now=now)
    assert (utc.reviewed_today, utc.streak) == (0, 1)  # yesterday in UTC, still alive


def test_time_zone_with_a_negative_offset(session):
    _review_at(session, datetime(2026, 11, 21, 3, 0, tzinfo=UTC))  # 19:00 on the 20th in LA
    now = datetime(2026, 11, 21, 20, 0, tzinfo=UTC)

    la = deck.stats(session, now=now, tz=LOS_ANGELES)
    assert (la.reviewed_today, la.streak) == (0, 1)
    utc = deck.stats(session, now=now)
    assert (utc.reviewed_today, utc.streak) == (1, 1)


def test_streak_across_a_dst_change(session):
    # Paris moves from UTC+1 to UTC+2 on 2026-03-29: 08:00 local is 07:00Z before, 06:00Z after.
    _review_at(session, *(datetime(2026, 3, d, 8, 0, tzinfo=PARIS) for d in range(27, 32)))
    now = datetime(2026, 3, 31, 10, 0, tzinfo=PARIS)

    stats = deck.stats(session, now=now, tz=PARIS)
    assert (stats.reviewed_today, stats.streak) == (1, 5)


def test_reviewed_today_uses_the_local_day_on_a_dst_day(session):
    # 2026-03-29 in Paris is 23 hours long: 2026-03-28T23:00Z to 2026-03-29T22:00Z.
    _review_at(
        session,
        datetime(2026, 3, 28, 22, 59, tzinfo=UTC),  # 23:59 on the 28th (UTC+1)
        datetime(2026, 3, 29, 22, 0, tzinfo=UTC),  # 00:00 on the 30th (UTC+2)
    )
    stats = deck.stats(session, now=datetime(2026, 3, 29, 12, 0, tzinfo=UTC), tz=PARIS)
    assert (stats.reviewed_today, stats.streak) == (0, 1)


def test_time_zone_rejects_unknown_names():
    assert deck.time_zone("Europe/Paris") == PARIS
    for name in ("Mars/Olympus", "", "../etc/passwd", "a" * 5000):
        with pytest.raises(deck.UnknownTimeZone, match=f"^Unknown time zone: {re.escape(name)}$"):
            deck.time_zone(name)


def test_deleting_a_card_keeps_its_review_history(session):
    _review_at(session, NOON - timedelta(days=1), NOON - timedelta(hours=1))
    [card] = deck.list_cards(session)
    before = deck.stats(session, now=NOON)
    assert (before.reviewed_today, before.streak) == (1, 2)

    deck.delete_card(session, card.id)

    after = deck.stats(session, now=NOON)
    assert (after.total, after.reviewed_today, after.streak) == (0, 1, 2)
    logs = session.exec(select(ReviewLog).order_by(col(ReviewLog.reviewed_at))).all()
    assert [(log.card_id, log.rating) for log in logs] == [(card.id, Rating.good)] * 2


def test_confidence_is_stored_and_does_not_change_scheduling(session):
    now = utcnow()
    plain, measured = deck.add_cards(
        session, [CardCreate(front="a", back="a"), CardCreate(front="b", back="b")], now=now
    ).added
    for rating in (Rating.good, Rating.again):
        later = now + timedelta(days=1)
        a = deck.review_card(session, plain.id, rating, now=later)
        b = deck.review_card(session, measured.id, rating, now=later, confidence=0.3)
        assert (a.due, a.last_review, a.state) == (
            b.due, b.last_review, b.state,
        )  # fmt: skip
        now = later

    logs = session.exec(select(ReviewLog).order_by(col(ReviewLog.id))).all()
    assert [log.confidence for log in logs] == [None, 0.3, None, 0.3]
