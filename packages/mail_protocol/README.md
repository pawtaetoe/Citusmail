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
| IMAP, SMTP | Coming in Stage 3 |

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

## Rules for callers

1. **SMTP must dot-stuff.** `MessageBuilder` output is RFC 5322 text. The
   SMTP client must double any line that starts with "." (RFC 5321 4.5.2)
   so a body line of "." cannot end the message early.
2. **Filenames from received mail are untrusted.** `MimePart.filename` is
   whatever the sender wrote, possibly `../../something`. Sanitise it before
   it is used as any part of a path.
3. **Raw header values are untrusted.** `HeaderField.value` may contain
   control characters. Use the decoded accessors on `MimeMessage`
   (`subject`, `from`, ...), which replace them, for anything shown or
   reused.
4. **HTML bodies are returned as sent.** Sanitising and blocking remote
   content is the renderer's job (Stage 8), tested with
   `test-data/mail/security/hostile-html.eml`.

## Tests

```bash
dart test            # run from this folder; reads ../../test-data/mail
```
