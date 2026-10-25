# Plan

How Citusmail is being built: the milestones, what each stage delivered,
what comes next, and the rules every stage follows.

Work goes milestone by milestone, in small stages. Each stage is planned
first, ends with something that can be run or tested, and is committed as
`Stage N <title>` once all checks pass.

## Milestones

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 | Own IMAP, SMTP and MIME code, encrypted local storage, sync, Smart Inbox, writing mail, custom folders, notifications, packaging | Done |
| M2 | Phishing checks, unsubscribe, blocking senders, tracker and image blocking, read-receipt blocking, app lock | Done |
| M3 | App data synced between devices (end-to-end encrypted), read receipts you ask for | Done |
| M4 | Outlook sign-in (OAuth 2.0) | Built; live check tool ready, run waiting on a client ID (Stage 24) |
| M5 | Gmail: app passwords first, then OAuth 2.0; signing in again | Built (Stages 25-27); live checks waiting |
| M6 | Server-side rules, on-device sorting model, optional Safe Browsing and VirusTotal | Server rules built (Stage 28) |

## Stages so far

### M1: a working mail client

| Stage | What it delivered |
| --- | --- |
| 1 | IMAP core and the unified inbox |
| 2 | Reading and building emails (MIME, charsets) |
| 3 | IMAP and SMTP clients over TLS |
| 4 | Encrypted local database |
| 5 | Offline sync into the encrypted store |
| 6 | First app prototype |
| 7 | Automatic sorting: Important, General, Notifications, Newsletters |
| 8 | Crash fixes and the three-pane UI |
| 9 | Writing mail: drafts, replies, sending with undo |
| 10 | Custom folders and folder rules |
| 11 | New mail notifications |
| 11.5 | Usability pass |

### M2: privacy and safety

| Stage | What it delivered |
| --- | --- |
| 12 | Phishing checks on the device: sender verification, lookalike domains, deceptive links, risky files |
| 13 | Unsubscribe: one-click (RFC 8058), by email, or the web page |
| 14 | Blocking senders and domains |
| 15 | Read-receipt blocking, tracker removal, images only on request |
| 15.5 | Signed Android build for Google Play |
| 16 | App lock with PIN or fingerprint |

### M3: sync between devices

| Stage | What it delivered |
| --- | --- |
| 17 | Sync format and encryption (ChaCha20-Poly1305, sync code) |
| 18 | Sync engine, through a folder in your own mail account |
| 19 | Sync between devices settings |
| 20 | Asking others for read receipts, and seeing them |

### M4: Outlook

| Stage | What it delivered |
| --- | --- |
| 21 | OAuth sign-in plumbing: PKCE, browser sign-in, tokens, XOAUTH2 for IMAP and SMTP |
| 22 | Outlook sign-in in the app |
| 23 | Design refresh (see [Design](#design)) |
| 24 | Live Outlook check tool: browser sign-in, token refresh (also mid-sync), XOAUTH2 IMAP and SMTP, sync, and with `--send` a message to the account itself |

### M5: Gmail

| Stage | What it delivered |
| --- | --- |
| 25 | Gmail with app passwords: built-in settings (no lookup), app password guidance and errors, Starred and Important synced only when opened, each message shown once across folders, archive to All Mail |
| 26 | Google sign-in for Gmail, offered next to app passwords: built-in client ID from the build, or the user's own ("bring your own"); accounts remember the client that signed them in; live check supports Google |
| 27 | Fixing a login without removing the account: "Sign in again" (OAuth, with the client that signed it in) and "Update password", from the account menu or the red status line; checked with a real login before it replaces the old one |

### M6: smarter and safer

| Stage | What it delivered |
| --- | --- |
| 28 | Rules on the mail server (opt-in): our own ManageSieve client (RFC 5804); blocked senders and folder rules written as one Sieve script, uploaded only when changed, never replacing another active script, removed when turned off; status per account in Settings |

## Next

1. **Run the Stage 24 live Outlook check.** The tool is ready
   (`dart run repo_tools:live_check --send`, see the README).
   - Waiting on: a Microsoft Entra client ID (see
     [packaging/README.md](packaging/README.md)) and an Outlook test account.
   - The app build takes the ID as `--dart-define=CITUSMAIL_MS_CLIENT_ID=...`;
     the live check reads it from `LIVE_OAUTH_CLIENT_ID` in `live-test.env`.
   - Its send step reports whether Outlook keeps its own copy in Sent (the
     app already adds no second copy when one with the same Message-ID is
     there).
2. **Run the live check against Gmail**, both ways:
   - with an app password (`LIVE_EMAIL=...@gmail.com`,
     imap.gmail.com:993, smtp.gmail.com:465);
   - with `LIVE_SIGN_IN=google` and a Google Cloud client (see
     [packaging/README.md](packaging/README.md)).
3. **Before a public Gmail release:** Google's verification of the
   built-in client ID (restricted scope: security assessment). Later,
   recognise Google Workspace addresses on their own domains (today they
   use the manual settings with an app password).
4. **Check server rules against a real Dovecot/Pigeonhole server** (the
   test server has no ManageSieve yet): add Pigeonhole to
   `test-server/`, and an integration test that a blocked sender's mail
   lands in Junk without the app.
5. **M6, the rest.**
   - An on-device model to improve sorting, with nothing sent anywhere.
   - Optional link and file checks with Google Safe Browsing (hash prefixes
     downloaded, links checked on the device) and VirusTotal (your own API
     key, only for items local checks flagged). Both off by default; each
     asks before it is turned on.

## Rules for every stage

- **Privacy and security are part of every stage**, not a later pass. The
  app talks only to your own mail servers and services you switch on.
  Every outside connection is listed in [PRIVACY.md](PRIVACY.md), and the
  protections in [SECURITY.md](SECURITY.md).
- **Our own protocol code.** IMAP, SMTP and MIME are written in this
  repository. No third-party mail libraries.
- **Correctness and reliability over speed.** Readable code, object-oriented
  where it fits, tested behaviour.
- **Every dependency is reviewed** and listed in
  [tool/dependency_policy.txt](tool/dependency_policy.txt). CI also checks
  which packages may open network connections.
- **Licence:** MPL 2.0 for our code. Bundled third-party files keep their own
  licences, listed in [NOTICE.md](NOTICE.md).
- **Live tests** use the real test account read-only, or send only to the
  account itself. Passwords stay in the system keychain, never in files.

## Design

Set in [app/lib/src/ui/fmail_theme.dart](app/lib/src/ui/fmail_theme.dart).

- **Colours:** a spruce sidebar (`#15332E`), lagoon green (`#0F7A69`) for
  actions and selection, and one citrus accent (`#F4B740`) for what needs
  attention first: unread counts and the New message button. All text meets
  WCAG AA contrast in light and dark mode.
- **Type:** IBM Plex Sans, bundled with the app, so nothing is downloaded.
- **Shape:** corner radii of 8 (small controls), 10 (rows, fields, buttons)
  and 20 (dialogs).
- **Layout:** Spark-like three panes on wide screens (sidebar, list, reader);
  list and reader on medium screens; one pane at a time on phones.
- **Heuristics:** changes are checked against Nielsen's ten usability
  heuristics. Examples:
  - Status is always visible (sync line, a status dot per account).
  - Buttons are labelled, and tooltips show keyboard shortcuts.
  - Actions are not repeated in two places.
  - Undo is offered after archive, delete and send.
- **Screenshots:** `cd app && flutter test screenshots/screens_test.dart`
  renders the main screens to `app/build/screens/` for before-and-after
  reviews.
