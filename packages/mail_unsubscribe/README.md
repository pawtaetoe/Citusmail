# mail_unsubscribe

Unsubscribing from newsletters safely. Pure Dart.

`UnsubscribePlanner.plan(message, trustReport)` reads `List-Unsubscribe`
(RFC 2369) and `List-Unsubscribe-Post` (RFC 8058) and returns the usable
methods, best first:

1. **One-click** (`OneClickMethod`): a POST of `List-Unsubscribe=One-Click`
   to the https link, sent through `mail_web`. Only when the user's own
   server verified a DKIM signature (see `mail_trust`) whose `h=` covers
   both `List-Unsubscribe` and `List-Unsubscribe-Post`; otherwise anyone
   on the way could have added the headers.
2. **Email** (`EmailMethod`): to the first `mailto:` address, with its
   subject and body (single line subject, control characters removed,
   length capped). Extra recipients (`cc=`, `bcc=`, more addresses) are
   ignored.
3. **Web page** (`WebPageMethod`): the https (or http) link, opened in the
   browser by the user.

Nothing is offered for mail with signs of a scam (lookalike or imitating
sender, deceptive links, dangerous files): unsubscribing there would only
confirm the address is read. The plan says why (`reason`). Each unsubscribe
address gets the same checks as links in a message
(`TrustChecker.checkLink`): a dangerous one is left out, an unusual one
comes with a warning. When the only problem is an unverified sender
(forwarding and some lists cause this), the methods are offered with a
warning (`warnings`), as is an unsubscribe address outside an unverified
sender's domain. Header parsing is bounded
(10 links, 4096 characters each).

```bash
dart test
```
