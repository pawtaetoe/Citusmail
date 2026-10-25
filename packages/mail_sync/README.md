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

## Custom folders and rules (`FolderRuleApplier`)

After the inbox is synced, the user's rules (from address, from domain,
sent-to address, subject contains) move matching new mail into its folder
on the server, in the same session, so every device and mail app sees it.
Mail servers like cPanel's have no server-side filters, so the app does it.

- A rule applies to mail received from its creation (10 minutes' tolerance
  for clock differences), or to everything with "also move existing".
- A message a rule moved once is never moved again (by Message-ID), so one
  the user brings back stays in the inbox.
- A rule goes when its folder goes (deleted or renamed elsewhere).
- New folders follow the server's layout (`FolderNames`): its separator,
  and the `INBOX.` prefix cPanel servers require.

## Blocked senders (`SenderBlocker`)

Before the folder rules run, new inbox mail from a blocked address or
domain (and its subdomains) moves to the account's Junk folder, chosen by
its `\Junk` flag, never by name (cPanel has both `INBOX.spam` with the
flag and a plain `INBOX.Junk`). Without a Junk folder it goes to Trash;
without either it stays. Same timing and "never twice" rules as folder
rules. `NewMailTracker` never announces blocked senders either.

## App data between devices (`AppDataSync`)

When the user has turned sync on (a sync code is in the keychain), the
sync account's normal sync ends with an exchange through its
`Citusmail Sync` folder (under `INBOX.` on cPanel-style servers):

1. read every device's snapshot message for this code (`X-Citusmail-Sync`
   header = the code's public sync id), each sealed with the code's key;
2. merge them with this device's data (`AppDataSnapshotter`: blocks,
   unsubscribes, image senders, folder rules, and their removals), keeping
   per item the later change;
3. apply the result here, and keep it (also what this device can't use,
   such as a rule for a folder it lacks, so it is never lost);
4. if anything changed, store a new snapshot as this device's one message
   and remove its old one (only its own: `UID EXPUNGE`).

Accounts and folders are named by address and folder name, not local ids.
The folder is never synced or shown as mail. A failure here is reported
(`appDataFailure`) but never fails the mail sync. The worker asks the UI
for the code each time it needs it (`SyncCodeProvider`); it is never
kept in the worker.

## Undo (`MailActions`)

Every action returns a receipt. Moves and deletes wait a few seconds
(`undoWindow`) before reaching the server; undo cancels the queued change
and restores the message exactly (summary, addresses, headers, body,
search text) from a snapshot taken when it left. Flag changes undo by
setting the flag back.

## Opening messages and older mail

- `SyncEngine.loadBody` downloads a whole message when the user opens it
  (BODY.PEEK, so opening alone never marks it read on the server), stores
  it encrypted and indexes its text for search. Messages over 50 MB are
  not downloaded.
- `SyncEngine.fetchOlder` loads the next page of older summaries.
- Both use `OnDemandConnections`: one connection per account, reused for a
  couple of minutes and closed when idle; requests on one account take
  turns, so a folder selected by one is never changed under another.

## Background worker (`SyncWorker`)

The app runs the engine in a background isolate, so syncing never makes
the UI stutter. The worker opens its own connection to the encrypted
database (transactions take the write lock up front, so the two
connections never fail each other); the UI reads what it writes.
Passwords are not given to the worker: it asks the UI for one at each
login, so only the UI isolate uses the keychain. If the worker crashes it
is restarted (at most three times in ten minutes).

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
CITUSMAIL_INTEGRATION=1 dart test test/integration   # needs test-server/citusmailtest up
CITUSMAIL_INTEGRATION=1 CITUSMAIL_CONVERGENCE_SEED=7 dart test test/integration --name converge
```

The convergence test runs three devices making random conflicting offline
changes and checks they all end up identical to the server.
