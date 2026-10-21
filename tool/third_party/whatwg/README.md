# WHATWG Encoding Standard data

Source data for the app's character set decoders.

| File | Source |
| --- | --- |
| `indexes.json` | https://encoding.spec.whatwg.org/indexes.json |
| `encodings.json` | https://encoding.spec.whatwg.org/encodings.json |

Downloaded 2026-10-21 (spec last modified 2026-10-19). Checksums are in
`SHA256SUMS`; verify with `sha256sum -c SHA256SUMS`.

Licence: [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/),
© WHATWG (Apple, Google, Mozilla, Microsoft). The generated tables in
`packages/mail_protocol/lib/src/charset/whatwg_data.g.dart` carry the same
attribution.

To update: download both files again, update `SHA256SUMS`, then run
`dart run repo_tools:generate_charset_tables` from the repository root and
run the `mail_protocol` tests.
