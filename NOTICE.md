# Third-party notices

The app's source code is licensed under the [Mozilla Public License 2.0](LICENSE).
It includes the following third-party data and libraries:

## WHATWG Encoding Standard

Character set tables and labels in
`packages/mail_protocol/lib/src/charset/whatwg_data.g.dart`, generated from
`tool/third_party/whatwg/`.

- Source: https://encoding.spec.whatwg.org/
- Copyright © WHATWG (Apple, Google, Mozilla, Microsoft)
- Licence: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
- Changes: the indexes are repacked (delta-encoded and compressed) for
  embedding; the mappings are unchanged.

## Public Suffix List

The table of domain endings in
`packages/mail_trust/lib/src/generated/public_suffixes.g.dart`, generated
from `tool/third_party/publicsuffix/`.

- Source: https://publicsuffix.org/
- Licence: [Mozilla Public License 2.0](https://mozilla.org/MPL/2.0/)
- Changes: comments removed; the rules are unchanged.

## SQLite and SQLite3MultipleCiphers

Bundled as a native library by `package:sqlite3` (see the root
`pubspec.yaml`).

- SQLite: https://sqlite.org, dedicated to the public domain.
- SQLite3MultipleCiphers: https://github.com/utelle/SQLite3MultipleCiphers,
  Copyright © Ulrich Telle, MIT License. It includes cipher implementations
  under their own permissive licences; see the upstream LICENSE file.
- `package:sqlite3`: https://github.com/simolus3/sqlite3.dart,
  Copyright © Simon Binder, MIT License.
