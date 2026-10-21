# mail_compose

Writing mail. Pure Dart; the app's compose window uses it.

- **`Draft`**: an immutable message being written (plain text).
- **`DraftStore`**: saves drafts on the device (encrypted, every few
  seconds while writing) and, when the window closes, moves them to the
  server's Drafts folder. The new copy is queued before the old one is
  removed, so a draft is never lost; old copies are found by Message-ID
  *and* the `\Draft` flag, so a real message can never be removed this
  way. Drafts left on the device after a crash go to the server at the
  next start.
- **`ReplyBuilder`**: Reply (to Reply-To when present), Reply all (never
  to the user's own addresses), Forward (with attachments); quoting and
  threading headers.
- **`Sender`**: sends through the outbox. The message waits 5 seconds so
  it can be undone; the send, the original's `\Answered` flag and the
  removal of the draft copy are queued together and undone together. It
  also works offline (it goes out with the next sync), and the outbox
  never sends twice (see mail_sync).

Sent mail carries no app name or version, a random Message-ID on the
sender's own domain, and its Date in UTC (no time zone).

```bash
dart test
```
