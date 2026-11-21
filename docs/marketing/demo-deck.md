# Demo deck

The deck every launch take is recorded with. Source of truth: `marketing/demo-deck.json`.
Seeded over REST into a **local throwaway API** by `marketing/seed-demo.sh`; never the real deck.

## Choice: English vocabulary + short facts

Everything is in English (project rule). Like the app's own sample cards (`serendipity`, `ephemeral`), the words
are uncommon but pleasant English words with a definition of a few words, so a broad audience reads front and
back in under a second. A few short facts add variety. The first card sets the calm tone:
**petrichor → the smell of rain on dry earth**.

## Cards (17)

12 words, 5 facts. Front = a word or a short question, back = the shortest answer.
"Due" cards are studied in this order (creation order). "Reviewed" cards get one `easy` review at seed time, so
they sit days ahead: the deck list shows a mix of "Due now · new" and "Due in N days · review", and the due count
lands on **8** (the number the widget spec uses).

| # | Front | Back | At seed |
|---|---|---|---|
| 1 | petrichor | the smell of rain on dry earth | due |
| 2 | ubiquitous | found everywhere | reviewed |
| 3 | luminous | full of light | due |
| 4 | Capital of Australia? | Canberra | due |
| 5 | candor | honesty | reviewed |
| 6 | halcyon | calm and peaceful | due |
| 7 | Berlin Wall fell in? | 1989 | reviewed |
| 8 | Au | gold | due |
| 9 | laconic | using few words | reviewed |
| 10 | mellifluous | sweet-sounding | due |
| 11 | wistful | gently longing | reviewed |
| 12 | ineffable | too great for words | due |
| 13 | Light from the Sun takes? | 8 minutes | reviewed |
| 14 | ebullient | full of energy | reviewed |
| 15 | Largest planet? | Jupiter | due |
| 16 | sanguine | hopeful | reviewed |
| 17 | equanimity | calm under stress | reviewed |

After seeding: `{"total":17,"due":8,"new":8,"reviewed_today":9}` and a real **1-day streak** (all seed reviews
happen "today"; the API can't backdate reviews over REST, and we don't fake it).

Not seeded, added on camera:
- **Video A** (typed in the app): `verdant` → `green with plants`.
- **Video B** (asked of the agent): `aurora`, `zenith`, `solace`. The agent writes the backs itself; the JSON's
  `agent_adds` only records what we expect (dawn light, highest point, comfort).

## Reproduce

```bash
TMP=$(mktemp -d)
LA_CARTE_DATABASE_URL="sqlite:///$TMP/demo.db" LA_CARTE_API_TOKEN=demo-token scripts/api-dev.sh &
marketing/seed-demo.sh            # LA_CARTE_API_URL defaults to http://127.0.0.1:8000, token demo-token
```

Safety built into the script: it refuses any URL that isn't `http://127.0.0.1` / `http://localhost`, and refuses
a deck that already has cards (use a fresh temp DB per take). The token is fake.

Point the simulator app at it with launch env `LA_CARTE_API_URL=http://127.0.0.1:8000` and
`LA_CARTE_API_TOKEN=demo-token`. The widget has no launch env (spec 007): it reads the URL and token saved in
Settings, so for widget takes enter the same two values in Settings once, **off camera**.
