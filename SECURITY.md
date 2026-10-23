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

## Releases

Android releases are signed with a key kept outside the repository (CI
reads it from repository secrets and deletes it after the build); a tagged
release refuses to publish a debug-signed APK. Each release lists SHA-256
checksums of its packages. Releases are created as drafts and published
by hand after review.

## Review

Each development stage ends with a security review of its changes before
it is marked done.
