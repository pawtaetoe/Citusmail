# mail_protocol

Pure Dart mail protocols for the app, written from scratch with no runtime
dependencies. See the root [SECURITY.md](../../SECURITY.md) for the rules
this package must follow.

## Layout

| Folder | What |
| --- | --- |
| `lib/src/charset/` | Character set decoders following the WHATWG Encoding Standard: UTF-8/16, all single-byte sets, GB18030/GBK, Big5, EUC-KR, Shift_JIS, EUC-JP, ISO-2022-JP. Tables are generated into `whatwg_data.g.dart` by `dart run repo_tools:generate_charset_tables` |
| `lib/src/mime/` | Reading mail: headers, RFC 2047 encoded words, addresses, Content-Type with RFC 2231, dates, Message-IDs, transfer encodings and the MIME tree (`MimeParser`) |
| `lib/src/mime/builder/` | Writing mail for sending (`MessageBuilder`) |
| `lib/src/net/` | Connections: TLS 1.2+ with full certificate checks, STARTTLS with injection protection, timeouts, size limits (`MailSocket`) |
| `lib/src/imap/` | IMAP client (`ImapClient`): login, folders with special use, SELECT with CONDSTORE/QRESYNC, FETCH, SEARCH, STORE with UNCHANGEDSINCE, MOVE, APPEND, IDLE |
| `lib/src/smtp/` | SMTP submission client (`SmtpClient`): implicit TLS or required STARTTLS, AUTH, dot-stuffing |

## Guarantees

- **Parsing never throws** on message content. Problems are recovered from
  and recorded as `MimeDefect`s.
- **Parsing is bounded.** Nesting depth, part count and header size are
  limited (`MimeParserLimits`), and every loop is linear in its input.
  The test suite fuzzes 2,000 mutated messages on every run.
- **Built messages cannot carry injected headers.** Control characters in
  text become spaces, and invalid addresses, IDs and types are rejected.
- **Built messages identify nothing about the sender's device**: no
  User-Agent or X-Mailer, the Date is in UTC, and Message-IDs are random.
- **Credentials only travel encrypted.** `ImapClient.login` and
  `SmtpClient.authenticate` refuse to run on an unencrypted connection.
  STARTTLS endpoints refuse servers that do not offer it, plain-text
  PREAUTH, and any data injected before the TLS handshake.
- **Nothing identifies the client to servers**: no IMAP `ID` command, and
  the SMTP greeting is the address literal `[127.0.0.1]`.

## Rules for callers

1. **Send with `SmtpClient.send`.** It dot-stuffs (RFC 5321 4.5.2) so a
   body line of "." cannot end the message early, and refuses partial
   sends: if any recipient is refused, nothing is sent.
2. **Filenames from received mail are untrusted.** `MimePart.filename` is
   whatever the sender wrote, possibly `../../something`. Sanitise it before
   it is used as any part of a path.
3. **Raw header values are untrusted.** `HeaderField.value` may contain
   control characters. Use the decoded accessors on `MimeMessage`
   (`subject`, `from`, ...), which replace them, for anything shown or
   reused.
4. **Choose special folders by `ImapMailboxInfo.specialUse`, never by
   name.** Namecheap, for example, has a plain `INBOX.Junk` next to the real
   `\Junk` folder `INBOX.spam`.
5. **Clients are single-use after a failure.** A timeout, protocol error or
   lost connection closes the client; create a new one. A server saying NO
   to one command does not.
6. **`uidMove` can be incomplete on old servers.** Without MOVE and UIDPLUS
   it returns `originalsMarkedDeleted: true`; the originals are expunged
   later, never with a plain EXPUNGE that could remove other devices' mail.
7. **HTML bodies are returned as sent.** Sanitising and blocking remote
   content is the renderer's job (Stage 8), tested with
   `test-data/mail/security/hostile-html.eml`.

## Tests

```bash
dart test                                   # unit tests (reads ../../test-data/mail)
CITUSMAIL_INTEGRATION=1 dart test test/integration   # needs test-server/citusmailtest up
```
