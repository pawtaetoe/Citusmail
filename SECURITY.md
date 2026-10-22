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
   simple document that has no way to express a remote resource, instead
   of a web view.
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

## Releases

Android releases are signed with a key kept outside the repository (CI
reads it from repository secrets and deletes it after the build); a tagged
release refuses to publish a debug-signed APK. Each release lists SHA-256
checksums of its packages. Releases are created as drafts and published
by hand after review.

## Review

Each development stage ends with a security review of its changes before
it is marked done.
