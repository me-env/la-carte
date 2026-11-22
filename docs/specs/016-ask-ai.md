# 016 — Ask about this card

Status: ready
Owners: **016a** ios-engineer (built together with 015b, same files), then **016b** ios-engineer.
Depends on: 015b (the double-tap menu on the revealed card), 014d (what each side shows). Backlog #35, #36.
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg (nothing new on screen at rest);
the system `.confirmationDialog` from 015b; Settings → Appearance (004) for the picker row.

## Goal
While studying, the user wants to ask an AI about a card (why is this the answer, give me an example). They
double-tap the revealed card, tap "Ask about this card", and land in their AI app with the card already written
out, ready to type a question. **016a** copies the text (the must-have). **016b** adds the app choice in Settings
and opens that app.

## Decisions to confirm with the user
1. **No "installed apps only" list.** None of these apps documents a URL scheme except Claude, so `canOpenURL`
   can't tell which are installed (table below). Settings lists every supported app. When the user taps Ask and
   the chosen app isn't installed, the text is still copied and the notice says so.
2. **The default is Vibe**, always (the request's rule "Vibe if installed, else the first installed one" needs
   install detection, see 1).
3. **Six choices**: Vibe, Claude, ChatGPT, Perplexity, Grok, Copy only. Gemini, Copilot, DeepSeek, Meta AI and Poe
   are left out: they have no documented link that opens their app (backlog #37: Gemini after a device check).
4. **The text is always copied**, even when the app link carries it. Claude and ChatGPT get it prefilled
   (Vibe: prefill doesn't work, user-tested 2026-11-22: copy + open);
   Perplexity and Grok open empty and the user pastes. Perplexity isn't prefilled on purpose: its link searches
   at once, before the user has typed a question.
5. **The menu loses its title.** With "Ask about this card" in it, "Report this card" no longer fits. The dialog
   shows the buttons only, Ask first (amends 015b #1; built together, so 015b's tests use the new shape).

## The text (exact)
```
This is the card <id> in the La Carte flashcard app.
Question: <prompt>
Answer: <answer>


```
As a Swift string: `"This is the card \(id) in the La Carte flashcard app.\nQuestion: \(prompt)\nAnswer: \(answer)\n\n"`.
It ends with the answer line's newline plus two more, so two empty lines follow the answer and the cursor sits on
the last one.

- `<id>`: the card's id, lowercase (`card.id.uuidString.lowercased()`), as the API and MCP print it.
- `<prompt>` / `<answer>`: what the card shows on each side (014d). Prompt = the card's `prompt` fields; answer =
  the `answer` fields, and for a `person` card every other non-empty field (014d #6). Empty fields are skipped.
  Fields keep `NoteType.fields` order.
  - **Basic** card: the field's text alone. `Question: la carte` / `Answer: the menu — and the map`. A reversed
    card swaps them, as on screen.
  - **Person** card: every field as `Label: value`, joined by `; `. The label is the field name capitalized. A
    photo is its URL. `Question: Photo: https://example.com/ada.jpg` /
    `Answer: Name: Ada Lovelace; Description: First programmer`.
- A side with no non-empty field prints nothing after `Question: ` / `Answer: `.

Built by a pure function in `StudyFeature`: `AskText.make(for card: Card) -> String`.

## AI apps (research 2026-11-21)
Each site's live `apple-app-site-association` file (AASA) was read: it lists the links iOS hands to the app.
"Unverified" means no official or concrete source.

| App | Link that opens the app | Prefilled prompt | Scheme (`canOpenURL`) | Decision |
|---|---|---|---|---|
| Mistral Vibe (was Le Chat, renamed May 2026) | `https://chat.mistral.ai/chat/` (AASA `/chat/*`; `/chat?q=` without the slash doesn't match) | `?q=` works on the web, ignored by the app (user-tested 2026-11-22) | none found | **Open + copy** (`/chat/`, slash kept for the AASA) |
| Claude | `https://claude.ai/new` (AASA, query kept) | `?q=` fills the box, doesn't send (official for desktop/web; iOS app unverified); ~14k chars cap | `claude://` (official) | **Prefill + copy** |
| ChatGPT | `https://chatgpt.com/?q=` (AASA routes `?q=` and `?prompt=` to the app) | `?q=` fills the box (community; auto-send unverified) | `chatgpt://` unverified | **Prefill + copy** |
| Perplexity | `https://www.perplexity.ai/search` (AASA) | `?q=` searches at once | `perplexity-app://` (community) | **Open + copy** (decision 4) |
| Grok | `https://grok.com/` (AASA, all paths) | `?q=` fills the box on the web; app unverified | `grok://` unverified | **Open + copy** |
| Gemini | only special paths (`/app/*?thread_id=`) open the app | browser extensions only | `googlegemini://` unverified | Skip (backlog #37) |
| Microsoft Copilot | only `/shares/*`, `/tasks`, `/conversations/join/*` | web only | `ms-copilot://` unverified | Skip |
| DeepSeek | none (no AASA) | none | unverified | Skip |
| Meta AI | media / posts only | none | unverified | Skip |
| Poe | poe.com paths | none | `poe://` unverified | Skip |

Sources: help.mistral.ai/en/articles/682992-le-chat-is-now-vibe; support.claude.com/en/articles/14729294 and
/14898120; community.openai.com/t/query-parameters-in-chatgpt/1027747; gist.github.com/pilotmoon/db804c1d2c6aa9e77a6ef38686053565
(Perplexity); the AASA file at `https://<host>/.well-known/apple-app-site-association` for each host above.

**How the app is opened**: only with these `https://` universal links, through
`UIApplication.shared.open(url, options: [.universalLinksOnly: true])`. It returns `false` when no installed app
claims the link, so there's no `LSApplicationQueriesSchemes` entry, no Safari fallback, and no Info.plist change.

**Prefill encoding**: `q` is percent-encoded so only RFC 3986 unreserved characters (`A–Z a–z 0–9 - . _ ~`) stay
literal. Newlines become `%0A`, spaces `%20`, `+` becomes `%2B`.

---

## 016a — Copy (ios-engineer, with 015b)

### Acceptance criteria (016a)
Mock = `LA_CARTE_API=mock` (+ `mock-notes` for person cards). "Double-tap the card" as in 015b.

| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | On a revealed card, double-tapping the card opens the dialog with no title and, in this order: "Ask about this card" (`study.report.ask`), the five 015b reasons, Cancel | unit + UI (light, dark) |
| 2 | Tapping "Ask about this card" copies `AskText.make(for:)` of the current card (through `askAI.copy`) and shows `study.reportNotice` "Copied" in the counter slot for 2 s, then `study.remaining` comes back | unit (`TestClock`, copied string recorded) + UI (notice) |
| 3 | `AskText.make`: basic card, reversed basic card, person `photo → name` card, person card with an empty description: the exact strings, ending in `"\n\n"` after the answer line, id lowercase | unit (Swift Testing) |
| 4 | Asking sends no request, leaves the card revealed, the buttons enabled and `remaining` unchanged | unit + UI |
| 5 | Ask is offered only when `canReport` (revealed, not editing, nothing in flight), like the reasons | unit |
| 6 | A rating, an edit start or a report clears the "Copied" notice | unit |

Screenshots: `study-ask-menu` (light + dark), `study-ask-copied` (light).

---

## 016b — Choose and open the app (ios-engineer, after 016a)

### Acceptance criteria (016b)
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Settings has a section "Ask AI" with a native menu `Picker` "App" (`settings.aiApp`) listing Vibe, Claude, ChatGPT, Perplexity, Grok, Copy only. Footer: "Ask about this card copies the card and opens this app." | unit + UI (light, dark) |
| 2 | First launch: the picker shows Vibe. A pick is stored in `@Shared(.appStorage("aiApp"))` and survives a relaunch | unit + UI |
| 3 | `AIApp.link(for:)` returns exactly: Vibe `https://chat.mistral.ai/chat/`; Claude `https://claude.ai/new?q=<enc>`; ChatGPT `https://chatgpt.com/?q=<enc>`; Perplexity `https://www.perplexity.ai/search`; Grok `https://grok.com/`; Copy only `nil`. `<enc>` as in "Prefill encoding" (test a text with a newline, `&`, `+` and `é`) | unit |
| 4 | Ask with an app chosen: copy first, then `askAI.open(link)`. Opened → notice "Copied". Not opened (app not installed) → "Copied · Vibe isn't installed" (the app's name). Both last 2 s (debug builds: `-noticeSeconds <s>` lengthens every notice, for slow UI-test runners) | unit (open stubbed `true` / `false`) |
| 5 | Ask with "Copy only": copies, calls no `open`, notice "Copied" (016a behaviour) | unit |
| 6 | Simulator, no AI app installed, default Vibe: Ask shows "Copied · Vibe isn't installed" and the app stays in front | UI |
| 7 | Left for the user (device): with Vibe, Claude and ChatGPT installed, Ask opens each one; Claude and ChatGPT show the text in their box; in Vibe, pasting gives the exact text | manual |

Screenshots: `settings-ai-app` (light + dark, menu open), `study-ask-not-installed` (light).

---

## Screens & states
Nothing new at rest. New states: the menu with Ask first (016a), the "Copied" / "Copied · X isn't installed"
notice in the counter slot (015b's notice style: `.meta`, `secondaryInk`, no pink, fades with
`Theme.Motion.standard`), and the Settings "Ask AI" section (016b), a standard `Form` row below Appearance.

## TCA shape (iOS)
**New client module `AskAIClient`** (no TCA; deps `Dependencies`, `DependenciesMacros`). `StudyFeature` and
`SettingsFeature` depend on it. 016a creates it with `copy` only; 016b adds `AIApp` and `open`.
```swift
public enum AIApp: String, CaseIterable, Sendable {      // 016b
  case vibe, claude, chatgpt, perplexity, grok, copyOnly
  public static let storageKey = "aiApp"
  public var title: String          // "Vibe", "Claude", "ChatGPT", "Perplexity", "Grok", "Copy only"
  public func link(for text: String) -> URL?
}
@DependencyClient public struct AskAIClient: Sendable {
  public var copy: @Sendable (_ text: String) -> Void                 // live: UIPasteboard.general.string
  public var open: @Sendable (_ url: URL) async -> Bool = { _ in false }  // 016b; live: universalLinksOnly
}
```
`testValue` unimplemented (macro); `previewValue` no-op copy, `open` returns `false`.

**StudyFeature**
- 015b's `ReportNotice` becomes `Notice` (`reported`, `failed`, `copied`, `copiedNotInstalled(String)`), and
  `reportNotice` becomes `notice` (`study.reportNotice` id unchanged). Same 2 s expiry for everything but `failed`.
- State (016b): `@Shared(.appStorage(AIApp.storageKey)) var aiApp: AIApp = .vibe`.
- Actions: `askTapped` (016a), `askOpened(Bool)` (016b).
- `askTapped`: `guard canReport, let card = cards.first`. Effect: `askAI.copy(AskText.make(for: card))`. 016a:
  `notice = .copied` and start the expiry. 016b: if `aiApp.link(for:)` is nil, as 016a; otherwise await
  `askAI.open(url)` and send `askOpened`, which sets `.copied` or `.copiedNotInstalled(aiApp.title)` and starts the
  expiry. Doesn't touch `isReviewing` or `cards`.
- View: the dialog becomes `.confirmationDialog("", isPresented:, titleVisibility: .hidden)` with
  "Ask about this card" first. The `.success` haptic stays on `.reported` only.

**SettingsFeature** (016b): `case aiAppPicked(AIApp)` writes the shared value with `withLock` (as `themeTapped`).
Picker with `.pickerStyle(.menu)`, bound like the theme picker.

**Docs** (in this change): `docs/architecture.md` lists the `AskAIClient` module.

## API / MCP changes
None. The text carries the card id, so an agent with MCP access can look the card up.

## Accessibility identifiers
New: `study.report.ask`, `settings.aiApp`. Reused: `study.reportNotice`, `study.card`, 015b's `study.report.*`.

## Out of scope
- Detecting installed apps; Gemini, Copilot, DeepSeek, Meta AI, Poe (backlog #37).
- A custom prompt template, or asking from the Deck or before reveal.
- An in-app AI answer.
- Accessibility (VoiceOver) tests: deferred.
