# mail_sync

Keeps the encrypted local store (`mail_store`) in step with the mail
servers, using the app's own IMAP and SMTP clients (`mail_protocol`).
Pure Dart.

## How a sync runs (`AccountSynchronizer`)

1. **Folder list**: LIST, stored with special-use flags.
2. **Queue replay** (`OutboxReplayer`): the user's offline changes go to the
   server first.
3. **Each folder** (`MailboxSynchronizer`), with the best method the
   server offers:

| Method | When | How changes are found |
| --- | --- | --- |
| full | first sync, or the server reset the folder (new UIDVALIDITY) | newest `initialWindow` messages (older ones with `fetchOlder`) |
| QRESYNC | server supports it (Namecheap, Dovecot) | removals and flag changes arrive with SELECT |
| CONDSTORE | change tracking without QRESYNC | flags changed since the last mod-sequence; removals by UID search |
| plain | no change tracking | compare all cached flags; removals by UID search |

New mail is fetched as summaries only (envelope, flags, structure, a few
headers, and a server-side preview when available), never whole messages.

## Rules that keep data correct

- **Interrupted syncs repeat safely.** Summaries are stored in batches and
  the folder's sync state is saved last; every write is an upsert.
- **Every queued action records UIDVALIDITY.** After a folder reset the same
  UIDs may mean other messages, so stale actions are failed, never applied.
- **Actions are idempotent.** A message already moved or deleted counts as
  done; appends are skipped when the Message-ID is already there.
- **No double sends.** "SMTP accepted" is recorded before saving to Sent, so
  a crash between the two never sends again, and Sent never gets two copies.
- **Local changes do not flicker back.** Folder syncs do not overwrite flags
  of messages with changes still in the queue.
- **Failures are classified** (`SyncFailure`): wrong password and
  certificate problems stop and ask the user; network errors retry with
  exponential backoff (30 s to 1 h, with jitter).

## Running (`SyncEngine`)

`start()` syncs every account, keeps an IDLE connection on each inbox
(changes appear within seconds), and runs a full sync every 15 minutes.
`requestSync()` after user actions merges bursts into one sync.

## Tests

```bash
dart test                                        # unit tests
FMAIL_INTEGRATION=1 dart test test/integration   # needs test-server/fmailtest up
FMAIL_INTEGRATION=1 FMAIL_CONVERGENCE_SEED=7 dart test test/integration --name converge
```

The convergence test runs three devices making random conflicting offline
changes and checks they all end up identical to the server.
