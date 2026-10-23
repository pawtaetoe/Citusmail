# mail_appsync

Keeps app data the same on all of the user's devices: blocked senders,
unsubscribes, folder rules and image senders. It travels through a folder
in the user's own mail account, end-to-end encrypted, so the mail server
(and its admin) sees only sealed data. Pure Dart, no dependencies beyond
`crypto` (SHA-256 and HMAC).

- **`SyncCode`**: 128 random bits shown as `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX`
  (Crockford base32 with a check character; forgiving about case, spaces,
  `O`/`0` and `I`/`L`/`1`). The first device makes it; the user types it
  once on each new device. Nothing is derived from a password, so there is
  nothing to guess.
- **Keys**: HKDF-SHA256 (RFC 5869) turns the code into an encryption key
  and a public sync id (which stored data belongs to this code).
- **`ChaCha20Poly1305`** (RFC 8439), written here and checked against the
  RFC's vectors and an independent implementation. The tag is verified
  in constant time before anything is decrypted.
- **`SyncRecord`**: one piece of data, or its deletion (a tombstone), with
  the time and device of the change. Merging keeps, per record, the later
  change; ties go to the deletion, then to the higher device id, so every
  device ends up with the same result.
- **`SnapshotSealer`**: a device's records as JSON, sealed as
  `CMSYNC1 | nonce | ciphertext+tag`, with the sync id and the device id as
  associated data. Not compressed, so sizes don't leak content mixed with
  text a sender controls. Limits: 50,000 records, 8 MB.

```bash
dart test
```
