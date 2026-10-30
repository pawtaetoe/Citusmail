# Mail fixtures

Sample messages shared by the test mail server (loaded by
`test-server/seed.py`) and the MIME parser tests. Files are byte-exact
(`.gitattributes` marks them `-text`). They are stored with LF line
endings; the seeder converts to CRLF for IMAP.

All addresses and links use reserved test domains (`.test`, `.example`),
except `github.com` in the GitHub notification, which the sorter needs to
recognise. Nothing here should ever be fetched over the network.

| File | What it tests |
| --- | --- |
| **people/** | |
| plain-text.eml | Simplest message; start of a thread |
| thread-reply.eml | `In-Reply-To` / `References` threading, quoted text |
| html-alternative.eml | `multipart/alternative`, quoted-printable with soft line breaks |
| attachment-inline-image.eml | mixed > alternative > related; `cid:` inline image; PDF attachment |
| latin1-quoted-printable.eml | ISO-8859-1 body and RFC 2047 Q-encoded `From` / `Subject` |
| japanese-iso-2022-jp.eml | ISO-2022-JP body and B-encoded headers |
| windows-1252-8bit.eml | 8-bit Windows-1252 body (curly quotes, euro sign) |
| rfc2231-filename.eml | RFC 2231 encoded, continued attachment filename |
| read-receipt-requested.eml | `Disposition-Notification-To` (must be ignored by default) |
| folded-headers-groups.eml | Folded headers, address groups, comments, escaped quotes, `Received` chain |
| **sent/**, **drafts/** | |
| lunch-reply.eml | Alice's reply in the lunch thread |
| report-with-receipt-request.eml | Sent mail that asked for a read receipt |
| unfinished.eml | Draft (`\Draft` flag) |
| **receipts/** | |
| mdn-displayed.eml | Incoming read receipt (`multipart/report`) matching `report-with-receipt-request.eml` |
| **newsletters/** | |
| one-click-unsubscribe.eml | RFC 8058 one-click, `mailto:` fallback, DKIM pass, tracking pixel, UTM links |
| one-click-dkim-fail.eml | Same headers but DKIM/DMARC fail, so one-click must not be trusted |
| mailto-only-unsubscribe.eml | Only a `mailto:` unsubscribe |
| web-link-only-unsubscribe.eml | Only a web unsubscribe link |
| body-link-only.eml | No unsubscribe header; link in body; `Precedence: bulk` |
| mailing-list-discussion.eml | `List-Id` on a human discussion list (sorting edge case) |
| forwarded-unverified.eml | Web unsubscribe, DMARC fail as after forwarding, no other sign of a scam |
| **notifications/** | |
| github.eml | Known service with `List-Id`: must sort as notification, not newsletter |
| bank-alert.eml | `no-reply@` sender |
| delivery.eml | `noreply@` sender |
| password-reset.eml | `do-not-reply@` sender |
| **security/** | |
| phishing-link-mismatch.eml | Link text vs destination mismatch, display-name spoof, SPF/DKIM/DMARC fail |
| punycode-lookalike.eml | Cyrillic lookalike domain (`xn--pple-43d`) |
| scam-with-unsubscribe.eml | Brand-imitating sender with a `List-Unsubscribe` header |
| org-impersonation-form.eml | Verified outside sender naming the reader's own institution, writing for IBM and Microsoft, hidden recipients, Google Forms "portal" link |
| risky-attachments.eml | `.html`, double-extension `.pdf.exe`, macro `.docm` (all harmless text) |
| hostile-html.eml | Every common way HTML loads remote content or runs script; renderer must make zero requests |
| **malformed/** | |
| missing-date-unknown-charset.eml | No `Date`, unknown charset |
| unterminated-multipart.eml | Closing boundary missing |
| raw-utf8-headers.eml | Unencoded UTF-8 in headers and address (SMTPUTF8 style) |
| deep-nesting.eml | Six levels of nested multipart |
| bad-base64.eml | Invalid base64 characters and padding |
| encoded-word-edge-cases.eml | Adjacent encoded words, broken and unknown-charset encoded words |

The DKIM signatures in the newsletters are fake. The `Authentication-Results`
header (written by the receiving server) is what carries the pass/fail
result the app should trust.
