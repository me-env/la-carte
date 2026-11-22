# small-glitches - PASS

Branch fix/small-glitches (d93120c). Screenshots: qa/screenshots/small/, qa/screenshots/small2/.

| # | Criterion | Result | Proof |
|---|---|---|---|
| 1 | Study swipe dots no longer cross text (halo) | PASS (by screenshot; ring is one a11y element, dot frames not measurable) | small/study-swipe-neutral-light.png, study-swipe-easy-dark.png |
| 2 | Deck offline has `deck.retry`; tap reloads when stub is back | PASS (testDeck_offlineThenRetry) | small/deck-offline-retry-light.png |
| 2b | Pull to refresh still works | PASS (RefreshUITests) | - |

Runs: ios-test.sh 226 passed. UI run (Ratings, Deck, Refresh; light + dark inside tests): 30 passed after fixing my own test (Deck uses /notes, not /cards), re-run green: 2/2.
Visual: halo subtle, no visible box in light/dark; retry button matches Study's circle style.
Bugs: none.
