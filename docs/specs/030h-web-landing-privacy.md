# 030h — Web: landing page, privacy policy, support page (served by the API)

Status: ready (can start now; deploy before the Google client is created, whose branding needs the privacy URL)
Owners: marketing (copy + media files) ∥ design-lead (look, note below) → api-engineer (pages, routes) →
code-reviewer → qa-validator; the manager shows the privacy text to the user before it deploys
Depends on: nothing. Touches `api/src/la_carte_api/app.py` (routes, public paths) and a new
`api/src/la_carte_api/site/` folder: if 030a is in flight in a worktree, rebase onto it (one small `app.py` conflict).
Supersedes 030b decision 9 and AC 17 (`/privacy` moves here). Overview: [030](030-accounts-google-login.md).
Design reference: the README visuals (`marketing/readme/`), the app icon (`/icon.svg`), the brand kit
(`docs/design/brand*`); Apple's App Store marketing guidelines for the badge.

## Goal
The App Store needs a public privacy policy and a support URL (5.1.1(i), App Store Connect). la-carte also gets a
one-page landing site: name, logo, a few screenshots, the demo videos, an App Store link, and links to privacy and
support. All on the API's existing domain, deployed with the API.

## Serving decision
**Static files served by the API** (FastAPI routes + `StaticFiles`), not a second container. It reuses the existing
domain, TLS, Dokploy service and the CI-gated deploy with zero new infrastructure; a second container would need its
own Dokploy domain/router rule and build for three HTML pages.

## User stories
- As a visitor, I open the site's root, see what la-carte is in ten seconds, watch it work, and find the App Store link.
- As an App Store reviewer or a user, I open `/privacy` and read what is collected and how to delete it.
- As a user with a problem, `/support` gives me an email address and how to delete my account.

## Decisions
1. **Files** in `api/src/la_carte_api/site/` (shipped in the wheel, so in the Docker image): `index.html`,
   `privacy.html`, `support.html`, `site.css`, `media/` (images and videos). Plain HTML + one CSS file, **no
   JavaScript, no external resources** (no CDN, no web fonts, no analytics, no cookies), system font stack,
   light/dark through `prefers-color-scheme`, readable from 320 pt wide. Total `site/` ≤ 4 MB.
2. **Routes** (public, registered before the MCP mount): `GET /` → `index.html`, `GET /privacy`, `GET /support`
   (HTML, `Cache-Control: public, max-age=300`), and `StaticFiles` at `/site` for `site.css` and `media/*`
   (`max-age=86400`). Before 030a, `BearerTokenMiddleware`'s public check accepts these three paths and the `/site/`
   prefix; from 030a on they are simply not behind `CurrentUser`. Links between pages are relative (`/privacy`),
   so no hostname is written anywhere.
3. **Placeholders**, filled once at startup from config, values HTML-escaped, no template engine:
   `{{support_email}}` (`LA_CARTE_SUPPORT_EMAIL`), `{{app_store_url}}` (`LA_CARTE_APP_STORE_URL`),
   `{{operator}}` (`LA_CARTE_OPERATOR_NAME`: who runs the service, shown in the privacy policy). A block wrapped in
   `<!-- if support_email -->…<!-- end -->` (same for the others) is dropped when the value is unset. Unset App Store
   URL → the badge block becomes the text "Coming soon to the App Store". Unset operator → "the developer of
   la-carte". No real hostname, email or name is committed.
4. **Landing (`/`)**, top to bottom (design-lead's note decides spacing and sizes; marketing writes the words):
   the app icon (`/icon.svg`, 96 pt) and "la-carte"; a one-line tagline; the App Store badge (Apple's official
   "Download on the App Store" artwork, black/white per scheme, linking `{{app_store_url}}`) or the "Coming soon"
   text; the app demo video (`<video muted autoplay loop playsinline>` with a poster, H.264 MP4, ≤ 1.5 MB); three
   screenshots (Study, a revealed card, the widget; light and dark variants through `<picture>` + media query);
   three short lines on what makes it different (one deck, spaced repetition, any AI agent can add cards over MCP)
   with the agent video (same rules); footer: "Privacy" · "Support" · "© la-carte". Every image and video has
   `alt` text / `aria-label` (marketing writes them). Media: reuse `marketing/readme/` stills and clips; the two
   MP4s come from marketing's existing cuts (`docs/marketing/app-demo.md`, `agent-video.md`). No real URLs, tokens,
   emails or personal data on any frame (marketing re-checks).
5. **Privacy policy (`/privacy`)**: the text in "Privacy policy text" below, verbatim apart from wording polish
   that doesn't change meaning. It must list every data type in `ios/LaCarte/PrivacyInfo.xcprivacy`
   (Email Address, User ID, Product Interaction, Other Diagnostic Data, Other User Content) and say the same
   purposes (app functionality only, no tracking). Any later change to the manifest or to what the server stores
   updates this page in the same change (added to `docs/architecture.md`).
6. **Support (`/support`)**: "Email {{support_email}}" (mailto link), "Delete your account: in the app, Settings →
   Delete Account. Or email us and we'll delete it within 30 days.", "Connect an AI agent: add this site's address
   followed by `/mcp` as a custom connector, then sign in." and a link to the privacy policy. Without a support
   email the page still renders the other lines.
7. Config: `LA_CARTE_SUPPORT_EMAIL`, `LA_CARTE_APP_STORE_URL`, `LA_CARTE_OPERATOR_NAME` (all optional) passed
   through `docker-compose.yml` with empty defaults; `docs/deploy.md` lists them.

## Privacy policy text
> **la-carte privacy policy** · Last updated: {date of deploy}
>
> la-carte is a flashcard app with spaced repetition. This service is run by {{operator}}. Contact:
> {{support_email}}.
>
> **What we collect**
> - **Your email address and an account identifier.** When you sign in with Google or Apple, we receive your email
>   address and that provider's identifier for your account, and we create our own account id. If you use Apple's
>   Hide My Email, we only get the relay address Apple gives us. We ask Google only for `openid email` and Apple
>   only for your email: never your name, photo or contacts.
> - **Your deck**: the notes and cards you or your AI agents create, including any photo links you add, and their
>   review history (each rating, with its date and how long it took).
> - **Reports and feedback**: card reports you file in the app and feedback you or your agents send.
> - **App activity**: what you do in the app (a card shown, revealed or rated, notes saved, the app opened or
>   closed, errors), with the app version, the iOS version and your time zone. It never contains card text. We
>   keep it for 90 days.
> - **Sign-in tokens.** Our own tokens are stored only as one-way hashes. For Sign in with Apple we keep a token
>   from Apple that is used only to revoke Apple sign-in when you delete your account.
>
> We don't collect passwords (la-carte has none), names, photos, contacts, location, payment details or
> advertising identifiers. There are no ads, no tracking and no third-party analytics.
>
> **Why**: to run the app (your deck, scheduling, the widget, the AI agents you connect) and to answer support
> requests. The legal basis is providing the service you asked for.
>
> **How your data is protected**: our database and its backups are encrypted at rest with a server key, so someone
> who steals the database file or a backup can't read anything in it, not even your email. This is not end-to-end
> encryption. The server decrypts your data to run the app and the AI agents you connect, so the server, and so the
> developer who runs it, can technically read your deck. (Spec 032; marketing's copy adds a short threat table.)
>
> **Who can see it**: you, through the app and the agents you connect. The developer can read the feedback you
> send and your related app activity, which never contains card text, to improve la-carte. The developer can
> technically read your deck too (see "How your data is protected") but doesn't look at it unless you ask or it's
> needed to keep the service running. We never sell or share your data. Google and
> Apple are used only to sign you in. Your data is stored on the server that hosts la-carte. When you connect an
> AI agent, what it reads from your deck is handled under that agent provider's own policy.
>
> **How long**: until you delete your account; app activity for 90 days. Server backups are kept up to 30 days,
> so deleted data leaves the backups within 30 days.
>
> **Delete your account**: in the app, Settings → Delete Account. It deletes your account, deck, review history,
> reports, feedback and activity right away, and revokes Sign in with Apple. Copies left in our encrypted backups
> are gone within 30 days. Or email {{support_email}}.
>
> **Your rights**: you can ask for a copy of your data, its correction or its deletion at {{support_email}}, and
> complain to your data protection authority.
>
> **Children**: la-carte is not directed at children under 13.
>
> **Changes**: we update this page and its date when this policy changes.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | `GET /`, `/privacy`, `/support` return 200 HTML without a token; `/site/site.css` and every file in `site/media/` return 200 with the right content type; `/mcp`, REST and the icons behave as before | pytest |
| 2 | No page or CSS loads an external resource: every `src` and stylesheet `href` is relative; links are relative, `mailto:` or `{{app_store_url}}`; no `<script>`; no `Set-Cookie` | pytest |
| 3 | With `LA_CARTE_SUPPORT_EMAIL=help@example.com`, `LA_CARTE_APP_STORE_URL=https://apps.apple.com/app/id0` and `LA_CARTE_OPERATOR_NAME=Example`, the pages show them (HTML-escaped: a value with `<` is escaped); with all unset, no page contains `{{`, `<!-- if`, an empty `mailto:` or a badge, and `/` shows "Coming soon to the App Store" | pytest |
| 4 | `/privacy` contains "openid email", "Hide My Email", "90 days", "Delete Account", "The developer can read the feedback you send", "no tracking", "encrypted at rest", "not end-to-end encryption" and a "Last updated" date (the 032 phrases as in marketing's draft on `web-030h`, 69cc2e8) | pytest |
| 5 | The committed `site/` text files contain no `http://` or `https://` URL and no email address: hosts and emails come only from the placeholders (a pytest scan) | pytest |
| 6 | `site/` is ≤ 4 MB; each video ≤ 1.5 MB; every `<img>` has `alt`, every `<video>` an `aria-label` and a `poster` | pytest |
| 7 | Every collected data type in `ios/LaCarte/PrivacyInfo.xcprivacy` has a matching line in `/privacy` (Email Address, User ID, Product Interaction, Other Diagnostic Data, Other User Content) | QA (read) |
| 8 | Full-page renders of `web-landing`, `web-privacy`, `web-support` at iPhone width and desktop width, light + dark, show no overflow, readable contrast, the videos' posters, and the badge or "Coming soon" | QA (screenshots) |
| 9 | After deploy: `<PUBLIC>/`, `/privacy`, `/support` load on the iPhone in Safari; the Google client's branding accepts `<PUBLIC>/privacy` (manager with the user) | manual |

## Design note (design-lead, to write before api-engineer builds)
One column, max width ~640 px, generous whitespace like the app; colours from the design-system tokens (ink,
secondary ink, background, the one pink accent) as CSS custom properties with a dark variant; the app's type scale
mapped to `-apple-system`/system-ui sizes; screenshots in a device-free rounded frame. Keep it as quiet as the app:
no gradients, no hero banner, no carousels. design-critic reviews the full-page renders (AC 8) before the user sees
them.

## API / MCP changes
New public routes `GET /`, `GET /privacy`, `GET /support`, static `/site/*`. No JSON change, no MCP change.

## Accessibility identifiers
None (web). Pages use semantic HTML (`header`, `main`, `footer`, one `h1`).

## Out of scope
- A web app, web sign-in, a blog, localisation, a cookie banner (no cookies), analytics, an Open Graph image,
  a separate domain. Terms of service (Apple's standard EULA applies unless the user wants one: backlog).
