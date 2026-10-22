# mail_web

The only code that makes HTTPS requests to servers named inside mail
(one-click unsubscribe, and images the user asks to load). Pure Dart,
built on `mail_protocol`'s `MailSocket`, so it follows the same TLS rules
as mail connections (TLS 1.2 or newer, full certificate and name checks).

What a request may do:

- **https on port 443 only**, to a host name. No IP addresses, no user
  names in the address, no non-ASCII names, at most 4096 characters.
- **Public addresses only.** The name is looked up first; if any address
  is loopback, private, link-local, carrier-grade NAT, multicast,
  documentation or reserved (also inside IPv6 mapped, NAT64 and 6to4
  forms), the request is refused. The connection then goes to the checked
  address while the certificate is checked for the name, so a second DNS
  answer can't redirect it.
- **Fixed request headers:** `Host`, `User-Agent: Mozilla/5.0`,
  `Accept: */*`, and the body's type and length. Never cookies, `Referer`,
  language or encoding preferences.
- **Redirects:** `post` never follows them (the 3xx is returned). `get`
  follows at most 3, and every address on the way is checked again: https,
  public address, and the caller's own test (the app refuses trackers).
- **Limits:** 20 seconds per request, 8 KB per header line, 100 headers.
  `post` doesn't read the answer's body; `get` reads it only for a 200,
  by `Content-Length` or in chunks, up to the caller's size limit, and
  refuses compressed or connection-delimited bodies.

The CI import check refuses `MailSocket.connect` anywhere else outside
`mail_protocol`, so this stays the single path.

```bash
dart test   # the TLS test uses test-server certificates when present
```
