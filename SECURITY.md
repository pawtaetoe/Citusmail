# Security

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's
**Security → Report a vulnerability** on this repository. Do not open a
public issue. We aim to reply within 7 days.

## What we protect

- Mail account passwords and tokens
- Message content, attachments and contacts stored on the device
- Who the user reads mail from and when (tracking, read receipts)
- The user's devices against hostile messages (phishing, malicious HTML,
  malformed MIME, risky attachments)

## Rules every change must follow

1. **Encrypted connections only.** TLS 1.2 or newer with full certificate
   and hostname checks. Plain-text IMAP and SMTP are refused. If STARTTLS
   is expected but not offered, the connection fails rather than
   continuing in plain text. A self-signed certificate is accepted only after an
   explicit warning, and then only that exact certificate (pinned by SHA-256).
2. **Secrets live in the system keychain only** (libsecret, Windows
   Credential Manager, Android Keystore). Never in the database, settings,
   logs or error messages. If no keychain is available the app refuses to
   save the secret.
3. **Local data is encrypted** (SQLite3MultipleCiphers with
   ChaCha20-Poly1305, random 256-bit key in the keychain). Opening fails
   closed if encryption is not available.
   Downloaded messages and their attachments stay inside the encrypted
   database. An attachment leaves it only when the user saves it: into
   Downloads, under a sanitised name, never overwriting a file and never
   opened automatically.
4. **Received mail cannot run or load anything by default.** No JavaScript,
   iframes, forms, remote images, CSS or fonts. No link or DNS prefetching.
   Links show their real destination before opening. Mail is shown with
   the app's own renderer (`packages/mail_view`), which turns HTML into a
   simple document instead of a web view. The only remote resource it can
   name is a content image, as an address; it is fetched only after the
   user asks, through `packages/mail_web`, and only a real PNG, JPEG, GIF
   or WebP of a size safe to decode is shown. Tracking pixels are left out
   of the document. Every image (embedded or loaded) has its header read
   first and is refused above 16384 pixels a side or 40 megapixels, and is
   decoded no larger than it is drawn.
   Every message is checked on the device for signs of phishing
   (`packages/mail_trust`). A suspicious message gets a red or amber
   warning that says why, its links open only after a warning where the
   safe choice is the main button, and risky attachments ask before they
   are saved. Sender verification uses only `Authentication-Results`
   written by the user's own server, never ones the sender could have
   added.
   Unsubscribing uses one-click (RFC 8058) only when the user's own server
   verified a DKIM signature that covers both unsubscribe headers;
   otherwise it falls back to an email or the sender's page.
5. **Logs contain no personal data.** No message content, addresses or
   tokens. Debug logging is off in release builds.
6. **Untrusted input is parsed defensively.** Everything from the network
   is untrusted. Parsers have size limits and are fuzz-tested.
7. **Dependencies are reviewed.** Every package is listed in
   `tool/dependency_policy.txt`. Versions are locked, CI scans them with OSV,
   and analytics, crash-reporting and ad SDKs are denied outright.
8. **Least privilege.** The Android app requests only the permissions it
   needs, blocks plain-text traffic, trusts only system certificate
   authorities and disables cloud backup of app data.
9. **Requests to servers named inside mail go through `packages/mail_web`
   only** (CI enforces this). That client uses https on port 443 to
   public addresses only: names that resolve into a private network
   (routers, `localhost`, cloud metadata) are refused. It sends no cookies,
   referrer or language, uses a generic user agent, never follows
   redirects, and enforces time and size limits. The certificate is
   checked for the name while connecting to the address that was checked.

10. **App lock is a gate, not encryption.** Mail is already encrypted at
    rest with a key in the system keychain; the lock keeps other people
    holding the device out of the app. The PIN (4 to 16 digits) is stored
    only as PBKDF2-HMAC-SHA256 (150,000 rounds, random salt) in the
    keychain and checked in constant time. After 5 wrong PINs, waits grow
    from 30 seconds to an hour, and survive restarts. While locked, the app
    is kept alive but not drawn, focusable or read by screen readers, the
    gate also covers every page and dialog, notifications hide sender and
    subject, and Android 13+ shows no app-switcher preview. "Forgot PIN"
    wipes the device's copy (accounts, passwords, mail, keys); nothing on
    the servers changes.

11. **Sync between devices is end-to-end encrypted.** A random 128-bit
    sync code (only in each device's keychain) gives, through HKDF-SHA256,
    the key for ChaCha20-Poly1305 (`packages/mail_appsync`, checked against
    RFC 8439 vectors and an independent implementation). Each snapshot has
    a fresh random nonce and is bound to the code's sync id and its
    device's id; anything changed or sealed with another code is refused
    before it is read. Devices only ever replace their own message, so
    neither a sync conflict nor a malicious copy can overwrite another
    device's data, and a removal can't be undone by an old copy.

12. **OAuth sign-in never handles the password.** Outlook accounts, and
    Gmail accounts that choose it, sign in on Microsoft's or Google's page
    in the user's own browser (authorization code flow with PKCE and
    `state`; RFC 7636, RFC 8252). The answer comes back to a one-time
    listener on 127.0.0.1 (desktops, and Android for Google) or the app's
    link (Android, Microsoft), and is accepted only for the sign-in the
    app started. Microsoft has no client secret; Google's desktop "client
    secret" is in every copy of the app and protects nothing, so security
    rests on PKCE, as for Microsoft. A user's own Google client ID and
    secret are kept in the keychain, and each account remembers which
    client signed it in, because its refresh token only works with that
    one. Access and refresh tokens live only in the keychain; IMAP and SMTP use them with
    SASL XOAUTH2 over TLS. A new password or sign-in for a saved account
    is checked with a real login before it replaces the old one, and an
    account signs in again only with the client that signed it in (or,
    with no earlier tokens, the build's or the user's own). Only the
    OAuth package may open a listening
    socket (CI enforces this).

13. **Rules on the mail server change only the app's own script.** When
    the user turns them on, ManageSieve (RFC 5804) is used over TLS only
    (STARTTLS required, credentials refused without it), with the same
    login as IMAP. The app stores one script, `citusmail`, and activates it
    only when the server runs no other script: a filter the user set up
    elsewhere is never replaced or edited. Every value in the script is
    escaped (quotes, backslashes, line breaks, `:matches` wildcards), so a
    rule can only file mail into a folder, never run other Sieve actions.
    The server checks the script before storing it. Turning the setting
    off removes the script.

14. **Outside checks are opt-in and minimal.** Google Safe Browsing runs
    only after the user turns it on and confirms. Its lists are checked
    on the device; a link is never sent, only the first 4 bytes of a
    matching SHA-256 fingerprint, to confirm. Lists are verified against
    Google's checksum and downloaded afresh when they don't match. All
    requests go through the hardened `mail_web` client. If a check can't
    be made in time, the link opens with the usual on-device warnings.
    VirusTotal, also opt-in, uses the user's own key and is only offered
    for what the on-device checks flagged, one tap at a time: files are
    looked up by SHA-256 and never uploaded, links are looked up and never
    submitted. Its API key is the only extra header `mail_web` can send,
    and only as a validated `X-` header.

## Releases

Android releases are signed with a key kept outside the repository (CI
reads it from repository secrets and deletes it after the build); a tagged
release refuses to publish a debug-signed APK. Each release lists SHA-256
checksums of its packages. Releases are created as drafts and published
by hand after review.

## Review

Each development stage ends with a security review of its changes before
it is marked done.
