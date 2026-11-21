from datetime import timedelta

from la_carte_api import deck
from la_carte_api.models import CardCreate, CardState, Rating, utcnow


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
