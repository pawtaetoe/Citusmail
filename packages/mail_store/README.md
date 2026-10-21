# mail_store

Encrypted local storage for the app. Pure Dart (no Flutter), built on
[`package:sqlite3`](https://pub.dev/packages/sqlite3) with
[SQLite3MultipleCiphers](https://github.com/utelle/SQLite3MultipleCiphers)
(selected in the root `pubspec.yaml` under `hooks: user_defines:`).

## What is stored

| Table | Contents |
| --- | --- |
| `accounts` | Email, servers, login name. **Never the password** (it lives in the system keychain under `Account.keychainKey`) |
| `mailboxes` | Folders, their special use, and sync state (UIDVALIDITY, UIDNEXT, HIGHESTMODSEQ) |
| `messages` | Summaries: subject, sender, dates, flags, size, list id, category |
| `message_addresses`, `message_headers` | Recipients, and the few headers sorting and unsubscribe need |
| `message_bodies` | Full raw messages that were downloaded |
| `message_search` | Full-text index (FTS5 trigram: works for every script) |
| `outbox` | Actions not yet confirmed by the server, replayed in order |
| `settings` | Small app-wide values (never secrets) |

## Guarantees

- **Encrypted at rest** with ChaCha20-Poly1305 (authenticated: tampering is
  detected) and a random 256-bit key from the keychain. The WAL file is
  encrypted too; temporary data never touches disk (`temp_store = MEMORY`);
  deleted data is overwritten (`secure_delete`).
- **Fails closed.** Opening refuses if the SQLite library cannot encrypt,
  if the cipher is not the expected one, or if the file on disk turns out
  to be plain SQLite.
- **All SQL uses bound parameters.** Search input is always literal text:
  FTS5 operators and LIKE wildcards typed by the user have no effect.
- **Atomic changes.** Multi-step updates run in transactions (nested ones
  use savepoints); a failed schema migration changes nothing.
- **The cache is rebuildable.** A wrong key or a damaged file can be
  handled with `MailDatabase.destroy` and a fresh sync. Only the outbox is
  local-only.
- **Safe with two connections.** The UI and the sync worker each open the
  database; transactions take the write lock up front (`BEGIN IMMEDIATE`)
  so neither can fail half-way because the other wrote.

## Notes

- Calls are synchronous. Run sync work off the UI isolate.
- Search terms shorter than 3 characters (e.g. two-character Chinese
  words) use a slower substring match on subject and sender instead of the
  index.

```bash
dart test        # first run downloads and verifies the native library
```
