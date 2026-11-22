# Liquid Glass audit (2026-11-22)

Question from the user: "maybe we have a mix of Liquid Glass and not; e.g. the report menu (spec 015) does not
have any. Should this be uniform?"

Short answer: **uniform does not mean glass everywhere.** On iOS 26 Apple puts Liquid Glass on one layer only:
the **controls and navigation layer** that floats above content (toolbars, toolbar buttons, tab bars, menus,
popovers, alerts, action sheets, and sheets at a *partial* detent). The **content layer** stays opaque (lists,
cells, cards, forms, full-height sheets, text). HIG: "Don't use Liquid Glass in the content layer"; use it
sparingly for the most important controls. So the rule is uniform by *layer*, and the audit checks each surface
against it.

Result: two inconsistencies. Mainly the **report / ask sheet**: it is a floating partial-height sheet (control
layer) but `.presentationBackground(Theme.background)` paints over the system glass, and its rows are opaque
`Theme.surface` slabs. Second, the offline **Retry** circle is glass inside a content message, next to the quiet "Open Settings" text action. Everything else is either system glass by default or opaque content on purpose (reviewed by design-critic).
Fix: spec [020](../specs/020-glass-consistency.md).

Method: code read of every view in `ios/LaCarteKit/Sources` + fresh UI-test screenshots, iPhone 17 Pro, light and
dark (`qa/screenshots/design-glass/`, run `design-glass`), compared with Apple's own iOS 26 apps (Notes, Reminders,
Mail, Photos, Maps, Settings) for the same kind of surface.

## Inventory and verdicts

| # | Surface | Where | Layer | Glass today | Apple's own iOS 26 apps | Verdict |
|---|---|---|---|---|---|---|
| 1 | Study top bar: Deck (`list.bullet`) and Add (`plus`) circles | `StudyView.topBar`, `CircleIconButton` | controls | Yes, `.glassEffect(.regular.interactive(), in: .circle)` | Toolbar buttons are glass circles (Notes, Mail) | **Keep.** Same 44 pt glass circle and 17 pt glyph as the system toolbar buttons on Deck/Settings/editor, so Study matches the sheets. Custom only because Study has no navigation bar (the card owns the screen) |
| 2 | Study counter / notices ("8 to review", "Reported", "Copied", "Couldn't save the edit") | `StudyView.topBar` | controls (title slot) | No (plain text) | Navigation titles and toolbar status text are plain text, never glass (Mail's "Updated just now") | **Keep.** Title-slot text, not a control |
| 3 | Card face (front, answer, photo, in-place edit field) | `StudyView.studying` | content | No | Content is never glass | **Keep.** The card is the content |
| 4 | "Show answer" and the rating row ("Forgot / Got it"; Hard/Easy by swipe) | `StudyView` | content actions | No (plain ink text, 44 pt) | Inline actions inside content are plain (Books, Notes); glass is for chrome that floats over scrolling content, and this row does not float over anything | **Keep.** Part of the card's reading flow (Apple's in-content primary actions, e.g. Books, Podcasts player, are not glass either); glass capsules would outweigh the one centered word (brand: quiet text row, `design-system.md` Screen patterns). Not glass is deliberate, not an omission |
| 5 | **Report / ask sheet** (double-tap the revealed card: "Ask about this card" + 5 reasons) | `StudyView.reportMenu` | controls (partial-detent sheet acting as a menu) | **No: `.presentationBackground(Theme.background)` overrides the system glass; rows are opaque `Theme.surface`** | Partial-height sheets are glass, inset from the screen edges (Maps, Find My, share sheet); menus are glass (`Menu`, context menus) | **Change (spec 020).** Drop the custom presentation background so the system glass shows; rows without opaque fill, like a system menu. The only surface that breaks the rule |
| 6 | "What's wrong?" comment alert (Other...) | `StudyView.reportMenu` `.alert` | controls | Yes (system alert) | System alert | **Keep.** System |
| 7 | Study offline Retry (`arrow.clockwise` circle) | `StudyView` offline | content action (inside a message) | **Yes** (`CircleIconButton`) | Empty-state actions are plain/bordered buttons in content | **Change (spec 020).** Glass on content breaks the rule, and its sibling message action "Open Settings" (#9) is quiet text: one look for message actions, a quiet "Try again" text button |
| 8 | Study messages: caught-up, empty, not set up, offline, token rejected | `StudyView.content` | content | No | `ContentUnavailableView`-style text is content | **Keep.** Content. (Text hierarchy vs Deck is the other audit's P1-3, not a glass question) |
| 9 | "Open Settings" quiet text button (Study + Deck messages) | `StudyView.settingsPrompt`, `DeckView.unavailable` | content action | No | Plain link-style action in empty states is common (Photos, Files) | **Keep.** Design-system pattern for setup messages (spec 008) |
| 10 | Deck, Settings, editor sheets (full height) | `AppView`, `DeckView` `.sheet` without detents | content | No: opaque `Theme.background` | Full-height (large) sheets are opaque in iOS 26; glass only at partial detents (Notes' settings, Reminders' new list) | **Keep.** Large sheets are opaque by design; the system glass would turn opaque at the large detent anyway |
| 11 | Toolbar buttons: Deck Settings + Add, editor `xmark`/`checkmark` (`role: .close/.confirm`), Settings `xmark` | `ToolbarItem`s | controls | Yes (system toolbar glass) | Same | **Keep.** System, and the confirm button is the system prominent glass |
| 12 | Deck search field | `.searchable(.navigationBarDrawer)` | controls | System search field | Same (Notes, Mail) | **Keep.** System |
| 13 | Deck list rows | `DeckView.row` | content | No: `Theme.surface`, radius 12 | Cells are opaque content | **Keep.** Content |
| 14 | Deck swipe-to-delete, context menu (Edit / Delete) | `.swipeActions`, `.contextMenu` | controls | Yes (system context menu glass; swipe action system) | Same | **Keep.** System |
| 15 | Deck messages (`ContentUnavailableView`, no matches, offline + Retry circle) | `DeckView.messageView` | content | Retry circle only | Same as #7/#8 | **Change (spec 020)** the Retry circle, as #7; the rest keeps |
| 16 | Settings form rows (server, token, Test connection, eye toggle) | `SettingsView` `Form` | content | No: `Theme.surface` rows | Form cells are opaque (Settings app) | **Keep.** Content |
| 17 | Theme segmented picker | `SettingsView.appearance`, `.pickerStyle(.segmented)` | control in content | System segmented control (glass thumb on iOS 26) | Same | **Keep.** System |
| 18 | Ask AI app picker | `.pickerStyle(.menu)` | controls | Yes (system menu glass) | Same | **Keep.** System |
| 19 | Editor form, type picker, note directions, photo preview | `NoteEditorView` `Form` | content | No (opaque rows); type picker system | Form content opaque | **Keep.** Content |
| 20 | Editor discard confirmation | `.confirmationDialog` | controls | Yes (system action sheet/popover glass) | Same | **Keep.** System |
| 21 | Launch / loading mark | `LaCarteLaunchMark`, `LaCarteLoadingMark` | content (brand) | No | Launch marks are flat | **Keep.** Brand drawing |
| 22 | Widget (systemSmall) | `DeckWidget`, `containerBackground(Theme.background, for: .widget)` | system-owned | System decides | On clear/tinted Home Screens iOS 26 removes the container background and draws its own glass | **Keep.** The removable `containerBackground` is exactly what lets the system apply glass; `widgetAccentable` handles tinted mode |

## Why not glass the rating row or the cards?

Apple's guidance is to keep glass for the layer that floats above content. Glass over the card face or the rating
row would put glass on content (HIG: don't), add refraction highlights at the bottom of a screen whose point is
one centered word, and fight the reference's quiet text row. The rule we follow is "glass where Apple's
own apps put it, nowhere else", which makes the app uniform by layer, not by material.

## Why not just switch the report sheet to a `Menu` or `.confirmationDialog`?

Both are glass, but neither has an anchor that works here: the trigger is a double tap on the card (no button),
and on iOS 26 a confirmation dialog pops over its source, which covered the answer the report is about (audit
2026-11-22 P0-1). The content-sized sheet below the card keeps the answer visible; it only needs the system's
sheet glass instead of a painted background. A long-press `.contextMenu` on the card would be the most native
alternative (it lifts the card instead of covering it), but that changes the gesture of spec 015, a product
decision left to the user.
