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
    state/        shared state types (LoadState, base view models)
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
  the code sees it. Inside, values are trusted.
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
  facade over focused controllers (selection, reading, actions, snooze,
  Screener, send later, …).
- **No behaviour change in a move.** Moving and renaming land on their
  own, with the full test suite passing, before any logic changes.
