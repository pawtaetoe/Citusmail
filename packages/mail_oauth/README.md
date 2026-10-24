# mail_oauth

Signing in to mail providers that no longer accept passwords for mail
apps (Outlook.com and Microsoft 365 first; Gmail later). Pure Dart. The
app never sees the user's password: they sign in on the provider's own
page in their usual browser.

- **`AuthorizationRequest`**: the authorization code flow with PKCE (RFC
  7636, S256) and a random `state`. Answers are accepted only at the exact
  redirect address with the right state; refusals and cancellations are
  told apart.
- **`LoopbackReceiver`** (desktops, RFC 8252): a one-time listener on
  `127.0.0.1` at a random port that takes exactly one answer, then closes;
  10 minutes at most. A code caught by another program is useless without
  the app's PKCE verifier. (Android uses an app link instead; see the app.)
- **`TokenClient`**: exchanges the code and refreshes tokens through
  `mail_web` (https, public addresses only, no cookies, no redirects). It
  is a public client: no client secret exists to leak.
- **`OAuthTokens`**: access and refresh tokens, for the system keychain
  only; renewed 5 minutes before they expire.
- **`OAuthProvider.microsoft`**: endpoints and scopes
  (`IMAP.AccessAsUser.All`, `SMTP.Send`, `offline_access`). The client id
  comes from the build (`--dart-define=CITUSMAIL_MS_CLIENT_ID=...`);
  without one, Microsoft sign-in is simply not offered.

IMAP and SMTP use the tokens through SASL XOAUTH2 (`mail_protocol`).

```bash
dart test
```
