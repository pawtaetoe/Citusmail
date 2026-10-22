# Public Suffix List

Source data for registrable-domain checks in `packages/mail_trust` (is a
link's real destination the same site as its text says?).

| File | Source |
| --- | --- |
| `public_suffix_list.dat` | https://publicsuffix.org/list/public_suffix_list.dat |

Downloaded 2026-10-23. Checksum in `SHA256SUMS`; verify with
`sha256sum -c SHA256SUMS`.

Licence: [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/),
maintained by the Public Suffix List project. The generated table in
`packages/mail_trust/lib/src/generated/public_suffixes.g.dart` keeps that
notice.

To update: download the file again, update `SHA256SUMS`, then run
`dart run repo_tools:generate_public_suffixes` from the repository root and
run the `mail_trust` tests.
