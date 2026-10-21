# Third-party notices

The app's source code is licensed under the [Mozilla Public License 2.0](LICENSE).
It includes the following third-party data:

## WHATWG Encoding Standard

Character set tables and labels in
`packages/mail_protocol/lib/src/charset/whatwg_data.g.dart`, generated from
`tool/third_party/whatwg/`.

- Source: https://encoding.spec.whatwg.org/
- Copyright © WHATWG (Apple, Google, Mozilla, Microsoft)
- Licence: [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
- Changes: the indexes are repacked (delta-encoded and compressed) for
  embedding; the mappings are unchanged.
