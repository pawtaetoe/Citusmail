# mail_setup

Finds and verifies mail server settings for a new account. Pure Dart.

## Discovery order (`AccountDiscovery`)

Most trustworthy first; stops at the first that works.

| # | Source | Trust |
| --- | --- | --- |
| 1 | Provider settings file over HTTPS (`autoconfig.<domain>`, `<domain>/.well-known/autoconfig`) | trusted |
| 2 | DNS SRV records (`_imaps._tcp`, `_submissions._tcp`, ...) via the system's own resolver | unauthenticated |
| 3 | Provider settings file over HTTP (cPanel often serves only this) | unauthenticated |
| 4 | Common host names (`<domain>`, `imap.`, `mail.`, `smtp.`), valid certificate required | unauthenticated |
| 5 | Mozilla's database, **only after the user agrees**, domain only | trusted (third party) |

Unauthenticated results are used only if their servers answer with a valid
certificate, and are flagged (`SetupWarning.unauthenticatedSource`) so the
user confirms them before the password is sent. Servers outside the
address's domain are flagged too (`serverOutsideDomain`).

## Privacy

- Only the **domain** is ever looked up. The full email address is never
  sent (unlike Thunderbird, no `?emailaddress=` parameter).
- Web requests carry no User-Agent and no cookies.
- DNS goes to the system's configured resolvers, never a public DNS
  provider. Where they cannot be found (Android, Windows), SRV lookup is
  skipped.

## Security

- Settings files are parsed by `MiniXml`, which refuses DOCTYPE (no XXE, no
  entity expansion) and limits size and depth.
- HTTPS redirects only to HTTPS; HTTP never redirects; responses over
  100 KB are refused.
- `AccountVerifier` checks settings with a real IMAP login and SMTP
  authentication before anything is saved. Certificate failures carry the
  certificate's name, so the user can be told "the certificate is for
  *.web-hosting.com" and offered a concrete alternative name.
- Plain-text servers are never offered or used.

```bash
dart test                                        # unit tests
FMAIL_INTEGRATION=1 dart test test/integration   # needs test-server/fmailtest up
```
