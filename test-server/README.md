# Test mail server

Local mail servers for development and integration tests. **Not for real
mail.** Everything runs in containers bound to `127.0.0.1`, and the servers
refuse to deliver anything outside `@fmail.test`.

```bash
test-server/fmailtest up       # build, create certificates, start, load sample mail
test-server/fmailtest smoke    # check the servers behave as the tests expect
test-server/fmailtest status   # ports, CA path, users
test-server/fmailtest reset    # fresh servers and fresh sample mail
test-server/fmailtest down     # stop and remove everything
```

Needs Podman (rootless is fine) or Docker, plus `python3`, `openssl` and
`curl`. Set `FMAIL_CONTAINER_RUNTIME=docker` to force Docker.

## Servers

One image (Dovecot 2.3 with Pigeonhole Sieve + Postfix on Ubuntu 24.04)
runs in three modes.
Ports are in [servers.env](servers.env).

| Mode | IMAP | IMAPS | Submission | Submissions | Purpose |
| --- | --- | --- | --- | --- | --- |
| secure | 10143 (STARTTLS required) | 10993 | 10587 (STARTTLS required) | 10465 | Normal testing. Full modern IMAP: IDLE, CONDSTORE, QRESYNC, MOVE, UIDPLUS, SPECIAL-USE |
| limited | 12143 | 12993 | 12587 | 12465 | TLS, but no CONDSTORE, QRESYNC or MOVE, to test fallbacks |
| plain | 11143 | none | 11587 | none | No encryption at all. Only for proving the app refuses it |

The secure server also offers ManageSieve on 14190 (STARTTLS required), for
the app's rules on the mail server: the active script runs on delivery.
Tests that store a script remove it again, and send nothing that would stay
in INBOX, since other tests count its messages.

## Users

| User | Password | Folder style |
| --- | --- | --- |
| `alice@fmail.test` | `alice-test-password` | `/` separator, nested `Projects/2026`, non-ASCII `日本語` |
| `bob@fmail.test` | `bob-test-password` | `/` separator (second account for the unified inbox) |
| `carol@fmail.test` | `carol-test-password` | Copies the real Namecheap layout: `INBOX.` prefix, `.` separator, `INBOX.spam` is the `\Junk` folder and `INBOX.Junk` is an ordinary folder |

These passwords are public test values.

Plus addressing works: mail to `alice+anything@fmail.test` lands in alice's
`anything` folder. Tests that send mail use this so the seeded folders never
change.

## Certificates

`certs/generate.sh` creates a local test CA and certificates in
`.generated/certs/` (git-ignored). The CA is name-constrained to the DNS
names `fmail.test` and `localhost`, so it can't vouch for any real site. Tests trust **only** `ca.crt` and never turn certificate checks off.

The hostname a client asks for (TLS SNI) picks the certificate:

| SNI name | Certificate | Expected client result |
| --- | --- | --- |
| `mail.fmail.test` (or `127.0.0.1`) | valid | connects |
| `expired.fmail.test` | expired in 2021 | refuses |
| `untrusted.fmail.test` | self-signed | refuses |
| any other name | valid, but for another host | refuses (hostname mismatch) |

## Sample mail

Fixtures live in [test-data/mail](../test-data/mail) and are shared with the
MIME parser tests. [seed.toml](seed.toml) says which message goes into which
user's folder, with which flags. The seeder ([seed.py](seed.py)) adds them
with IMAP APPEND over TLS. It refuses to touch anything except
`127.0.0.1` and `@fmail.test`, and refuses to add mail twice.

## Why slirp4netns on rootless Podman

Podman's default rootless networking makes every connection look like it
comes from the server itself. Dovecot then treats plain-text connections as
secure and allows login before STARTTLS, unlike a real server. `fmailtest`
uses slirp4netns, which keeps the addresses apart so TLS rules are enforced.
The smoke test checks this ("login before STARTTLS is refused").
