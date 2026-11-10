# mail_pairing

"Add accounts from your phone": the computer shows a QR code, the phone
scans it and sends the mail accounts the user picks. Pure Dart, no
server in between: the two devices talk directly over the local network,
or, when they can't reach each other, the phone hands over a sealed file.

- **The QR code** (`PairingOffer`):
  `citusmail-pair:?v=1&a=<addresses>&p=<port>&k=<key>&t=<token>`: the
  computer's local network addresses and a random port, a one-time X25519
  public key, and a random 128-bit token. Codes naming an address outside
  the local network (private IPv4 ranges, IPv4 link-local, IPv6 unique
  local, loopback) are refused, so a crafted code can't make the phone
  send anything to the internet.
- **The connection** (`PairingHost` on the computer, `PairingClient` on
  the phone): length-prefixed messages over TCP. The phone sends a new
  X25519 key of its own; both sides derive two keys (one per direction)
  and a six-digit check code with HKDF-SHA256 from the X25519 secret,
  with the token as salt. Every later message is sealed with
  ChaCha20-Poly1305 under a message number, so a replayed, dropped or
  changed message fails. The phone's first sealed message proves it
  scanned the code; the computer's answer proves it holds the key from
  the code, so nobody on the network can sit in the middle.
- **One time**: the computer stops listening once a phone has connected,
  after 5 minutes, or after 5 connections with a wrong key or token. One
  transfer only; afterwards the private key is wiped.
- **The file** (`PairingFile`, `citusmail-accounts.cmpair`): the same
  accounts sealed on the phone to the computer's key from the code
  (`CMPAIR | version | code id | phone key | nonce | ciphertext+tag`, the
  header as associated data). Only the computer showing that code can
  open it, for 15 minutes: its private key never leaves its memory.
- **X25519** (RFC 7748) is written here and checked against the RFC's
  test vectors. It uses big integers and is not constant-time; each key
  is used for one pairing and lives for minutes.

```bash
dart test
```
