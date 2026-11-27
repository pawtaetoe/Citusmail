# Citusmail architecture

How the code is laid out, which code may depend on which, and the
conventions every change follows. It follows Flutter's own app
architecture guide (a UI layer of views and their view models over a data
layer of repositories and services), arranged by feature.

## The two halves

**`packages/`** hold everything that isn't Flutter UI, each with one job
and its own tests: `mail_protocol` (IMAP, SMTP, MIME), `mail_store` (the
encrypted database and its repositories), `mail_sync`, `mail_compose`,
`mail_sort`, `mail_trust`, `mail_view`, `mail_ai`, `mail_oauth`,
`mail_setup` and the rest. They never import Flutter UI.

**`app/`** is the Flutter app. Its code lives in `app/lib/src`:

```
app/lib/src/
  app/            starting the app, the lock, the top-level navigation
  core/           shared by every feature, depends on no feature
    theme/        colours, type, spacing, radii, motion, icons
    widgets/      small shared widgets (avatar, badge, empty state, page
                  scaffold, confirm dialogs, …)
    text/         wording shared across features (mail_text)
    state/        shared state types (LoadState, base view models) and
                  the validation toolkit (validation.dart)
  services/       app-wide services: settings, notifications, the AI
                  assistant, device sync, secrets (data layer)
  features/
    inbox/        the shell, sidebar, list, rows, peek, summary line,
                  search, command bar
    reader/       reading an email and what is shown with it
    compose/      writing, sending, send later, sign-offs, writing help
    found/        subscriptions, deliveries, returns, trips, appointments,
                  attachments
    organise/     Screener, snooze, follow-ups, clean up, block, move,
                  folders, unsubscribe, privacy report
    accounts/     adding (setup), pairing, online accounts
    settings/     the settings pages and their search
    ai/           the AI assistant's settings and panels
    discover/     All features, What's new, tips, keyboard shortcuts
    security/     the app lock
  background/     the Android background check
```

Inside a feature, `ui/` holds widgets (views) and `state/` holds view
models, controllers and the plain logic behind them (`ChangeNotifier`,
`ValueNotifier`, value types: no widgets).

## Who may import what

Checked on every pull request by `dart run repo_tools:check_imports`
(`tool/lib/src/layer_checker.dart`):

- `core/` imports no feature, no service, nothing from `app/`.
- `services/` and every `state/` folder import no widget code (`ui/`,
  `core/widgets/`, `package:flutter/material.dart`): they can be tested
  and reused without a screen.
- Network code only where the existing rules allow it (unchanged).

A feature's `ui/` may use its own `state/`, `core/`, `services/` and
other features where the screens really meet (the inbox opens the
reader; the reader offers snooze). Keep those links few and pointing one
way; a type two features both need belongs in the lower one's `state/` or
in `core/`.

## The mail screen's controllers

`MailController` (`features/inbox/state/mail_controller.dart`) is what
the mail screen holds. It is a facade: it makes the focused controllers
below, wires them together, and keeps the screen's API by handing each
call to the one whose job it is. New code can use a focused controller
directly (each is a public field, such as `controller.snoozeController`).

| Controller | File (under `features/`) | Its job |
| --- | --- | --- |
| `SyncStatusController` | `inbox/state/sync_status.dart` | the sync worker's events and the status line (`status`), sync now, reconnect |
| `CountsController` | `inbox/state/mail_counts.dart` | sidebar and section counts (`counts`), read again only when the store changed |
| `ComposeStarter` | `compose/state/compose_starter.dart` | new messages, replies, forwards and drafts in the compose window (`onCompose`) |
| `ReaderController` | `reader/state/reader_controller.dart` | the open message (`reader`): opening, next and previous, images, read receipts |
| `SelectionController` | `inbox/state/selection_controller.dart` | messages picked for a bulk action (`selection`) |
| `LocationController` | `inbox/state/location_controller.dart` | where the user is (`location`), search, loading older mail |
| `MessageActions` | `inbox/state/message_actions.dart` | pin, read, archive, move, delete, "Not spam", with Undo; leaving the list |
| `FolderController` | `organise/state/folder_controller.dart` | new folders, where mail can move, folder rules |
| `WakeTimer` | `organise/state/wake_timer.dart` | a timer for the next snooze or follow-up due |
| `SnoozeController` | `organise/state/snooze_controller.dart` | snooze, unsnooze, waking snoozed mail |
| `FollowUpController` | `organise/state/follow_up_controller.dart` | "Remind me if no reply" |
| `AwayController` | `inbox/state/away_controller.dart` | leaving and coming back, "New since you were away" |
| `OldCodesController` | `organise/state/old_codes_controller.dart` | tidying up old verification codes (`codesOffer`) |
| `UnsubscribeController` | `organise/state/unsubscribe_controller.dart` | unsubscribing from a list |
| `BlockingController` | `organise/state/blocking_controller.dart` | blocking and unblocking senders |
| `ScreenerController` | `organise/state/screener_controller.dart` | the Screener's first-time senders |
| `InvitationController` | `reader/state/invitation_controller.dart` | answering calendar invitations |
| `OutboxController` | `compose/state/outbox_controller.dart` | failed sends and "Send later" |
| `AccountOrder` | `accounts/state/account_order.dart` | the accounts' order (`accountsChanged`) |

Each is a plain class (with `ValueNotifier`s where the screen listens)
that takes what it needs in its constructor: services, the store, the
message list and the other controllers it uses. They depend on each
other one way only, in the order `MailController` makes them (an arrow
reads "uses"):

```
SyncStatusController, CountsController, ComposeStarter, AccountOrder,
InvitationController                        (no other controller)
ReaderController      -> CountsController, ComposeStarter
SelectionController   -> (the open message, by a callback)
LocationController    -> SelectionController
MessageActions        -> LocationController, SelectionController,
                         ReaderController
FolderController      -> LocationController, CountsController
SnoozeController      -> LocationController, SelectionController,
                         ReaderController, MessageActions, WakeTimer
FollowUpController    -> WakeTimer
AwayController        -> MessageActions, SnoozeController,
                         FollowUpController
OldCodesController    -> ReaderController, SelectionController
UnsubscribeController -> ReaderController, MessageActions
BlockingController    -> ReaderController, MessageActions
ScreenerController    -> MessageActions
OutboxController      -> ComposeStarter
```

What goes back the other way is a callback the facade passes in:
`refresh` (re-read the list, the counts, the open message and the
Verification offer, and set the wake timer), `notify` (a notice with
Undo, shown through `onNotice`), the viewed account for
`ComposeStarter`, and the wake timer's `onDue` (wake snoozed mail, then
check follow-ups). After each sync the facade tidies old codes, wakes
snoozes and checks follow-ups, then refreshes once. `dispose` stops the
timers, the sync events and the sorter's listener first, then disposes
the controllers, those that use others first.

Each controller has its own tests that build it without the facade or
a widget (`app/test/support/controllers.dart` wires them by hand).

## Conventions

- **Types over strings.** Ids are extension types (`MessageId`,
  `AccountId`, `MailboxId`), not bare `int`s. Settings are typed
  `Setting<T>` values with a key, a default and a codec, not strings read
  as `'on'`/`'off'`. Feature and command ids are enums or constants, never
  free text at call sites.
- **States are sealed classes.** Loading, ready, failed: a `switch` over a
  sealed type, so a forgotten case doesn't compile.
- **Validate at the edges.** Anything typed by the user or arriving from
  outside (addresses, host names and ports, URLs, numbers, folder names,
  pairing and import files, mailto links, AI answers) goes through a
  validator that returns a typed value or a reason, before the rest of
  the code sees it. Inside, values are trusted. See
  [Validation at the edges](#validation-at-the-edges).
- **Shared behaviour in base classes, not copies.** Inheritance only where
  the "is a" holds; otherwise composition. The bases:
  - `LoadState<T>` (`core/state/load_state.dart`): sealed `Loading`,
    `Loaded(value)`, `LoadFailed(reason)`. Pages show it with a `switch`.
  - `PageModel<T>` (`core/state/page_model.dart`): extend it for a view
    model that loads a page's data. Write `fetch()`; it owns the state,
    runs one fetch at a time (the newest `load()` wins, a stale result is
    dropped), keeps the data while loading again, reloads on a
    `reloadOn` listenable, and is safe after `dispose`. Not for paged
    lists or models that work out their data synchronously (the message
    list, the summary line, attachments).
  - `FoundModel<T, F>` (`features/found/state/found_model.dart`), on
    `PageModel`: a "Found in your mail" page (subscriptions, deliveries,
    trips, appointments, online accounts). It does "Not a …" with Undo,
    "List again", learning from corrections and reading emails on
    request; the page gives its finder, mail kind, keys and samples.
  - `AiTask<R>` (`features/ai/state/ai_task.dart`): one request to the AI
    assistant, with a sealed `AiTaskState` (idle, running with the text so
    far, done, failed with a plain message, stopped). Extend it when the
    request is the thing (a writing run, a translation, quick replies);
    hold one when a screen asks (the summary card, the tidy sheet). The
    feature keeps its prompt (`MailPrompt`), checks and cache and asks
    through its `AiFeatureProvider`; `run` gives it the cancel token and
    the streaming, `explain` words the problems.
  - `DetailScaffold` with `DetailHeader`, `DetailFact` and
    `DetailSection` (`core/widgets/detail_scaffold.dart`): the page of
    one thing found in the mail. Its emails open in `EmailPage`
    (`features/reader/ui/email_page.dart`).
  - Smaller shared pieces: `confirmDialog` (`core/widgets`) for "Are you
    sure?" questions; `found_parts.dart` for the found pages' read offer,
    reading progress, section titles and `LeftOutList`.

  Before copying a widget or a state machine a third time, fold it into
  one of these or a new shared piece.
- **Small classes.** A controller does one job. `MailController` is a
  facade over focused controllers (see "The mail screen's controllers"
  above); a new mail screen feature gets its own controller, not more
  code in the facade.
- **No behaviour change in a move.** Moving and renaming land on their
  own, with the full test suite passing, before any logic changes.

## Validation at the edges

The toolkit is `app/lib/src/core/state/validation.dart` (no widgets). A
check gives a sealed `Validated<T>`: `Valid(value)` or `Invalid(reason)`,
where the reason is a short sentence for the user ("Enter a port
number"). Validators are small classes called like functions, and
`.field` adapts one to a form field's `validator:`:

| Validator | Gives | Rules |
| --- | --- | --- |
| `TextInput` | `String` | trimmed, one line unless `multiline`, no control characters, at most `maxLength` |
| `WholeNumber`, `Port` | `int` | plain digits in a range (1 to 65535) |
| `Amount` | `double` | `5`, `0.25`, `0,25`, `$5`; never NaN, infinite or an exponent |
| `EmailAddress` | `MailAddress` | the mail parser (`AddressParser`), and with `sendable` the message builder's own check (`HeaderEncoder.validateAddress`) |
| `HostName` | `String` | ASCII letters, digits and hyphens in two or more parts, lower case |
| `WebAddress` | `Uri` | https, or http to a host that may be on the user's network; no other scheme, no user name in it |
| `FolderName` | `String` | the sync layer's rules (`FolderNames.problemWith`) |
| `SearchText`, `ApiKey`, `ModelId`, `MatchingText` | `String` | lengths, no spaces or control characters, a known shape |

Where a package already checks something correctly, the validator calls
it rather than repeating it (the address parser, the message builder,
`AccountDiscovery.supportsAddress`, `FolderNames.problemWith`,
`OAuthRegistration.problemFor`, `PublicAddressPolicy`). A feature's own
combinations live in its `state/`: `AccountFields` (setup and pairing),
`ComposeFields` and `MailtoLink` (compose).

In a form, the reason shows under the field as it is typed (nothing
while a field is still empty), Save stays off until every field is
valid, and the checked value, not the raw text, goes on to controllers
and services. What is already stored is never checked again in a way
that loses it: a stored value that can't be read reads as its default
and stays as it is until the next write.

The edges:

- **Account setup** (`features/accounts`): the address, the name, the
  server names, ports and user name (`AccountFields`), the password (not
  empty, otherwise taken as typed), the own OAuth client ID
  (`OAuthRegistration.problemFor`).
- **Pairing and import** (`mail_pairing`, `account_import.dart`): the
  transfer's reader bounds every text, count and port (`TransferLimits`);
  the computer then checks each account with `AccountFields` before
  signing in to anything. Files are size-checked before they are read.
- **Compose**: typed and pasted recipients (`RecipientList.check`: the
  parser, then the builder's check, at most 500), the subject (one line),
  picked files (size before reading, a clean name). Headers are also
  made safe by the message builder itself.
- **Links**: `mailto:` (`MailtoLink.parse`), notification payloads and
  Copy code ids (`MailNotices.messageIdOf`, `CopyCodeAction.parse`),
  command bar ids (`CommandId.parse`), OAuth redirects (state and
  address checked by `mail_oauth`), pairing QR codes
  (`PairingOffer.decode`).
- **Folders**: new folder names (`FolderName`); folder rule values are
  checked by the store.
- **Search**: the search field and the command bar (`SearchText`).
- **AI settings**: keys (`ApiKey`), the custom endpoint (`WebAddress`),
  model names (`ModelId`), the monthly limit and prices (`Amount`; the
  ledger also refuses a limit that isn't finite). Per-sync counts and
  other numbers in Settings are chosen from lists; their stored values are
  read within range (`IntSetting`).
- **Other settings**: sign-offs (`TextInput`), the VirusTotal and Safe
  Browsing keys (`MatchingText`, shared with the services), the sync
  code (`SyncCode.parse`).
- **Stored settings**: every `Setting<T>` decoder reads a value it can't
  use as its default, never throws.
