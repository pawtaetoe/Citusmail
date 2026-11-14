// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_store/mail_store.dart';

/// A private header on the copy of a draft kept in the user's Drafts
/// folder: which sign-off ends it, so the draft opens again with its
/// sign-off apart from the text, also one written for that email only.
/// It is never on a message that is sent (see `OutgoingMessage`'s
/// `draftHeaders`).
abstract final class SignOffHeader {
  static const name = 'X-Citusmail-Sign-off';

  static const _none = 'none';

  /// The header's value: `none`, or the sign-off (id, text, separator)
  /// as base64 JSON, in short pieces so the header folds.
  static String encode(SignOff? signOff) {
    if (signOff == null) return _none;
    final data = base64.encode(
      utf8.encode(
        jsonEncode({
          'id': signOff.id,
          'text': signOff.text,
          if (signOff.separator) 'sep': true,
        }),
      ),
    );
    return [
      for (var i = 0; i < data.length; i += 60)
        data.substring(i, i + 60 > data.length ? data.length : i + 60),
    ].join(' ');
  }

  /// What [value] says: null when there is no readable header (an older
  /// draft, or one from another app); a record with no sign-off for
  /// `none`. A saved sign-off comes back with its id and the text it had
  /// in the draft.
  static ({SignOff? signOff})? decode(String? value) {
    if (value == null) return null;
    final compact = value.replaceAll(RegExp(r'\s'), '');
    if (compact == _none) return (signOff: null);
    try {
      final json = jsonDecode(utf8.decode(base64.decode(compact)));
      if (json case {'id': final String id, 'text': final String text}) {
        final separator = json['sep'] == true;
        final oneOff = SignOff.oneOff(text: text, separator: separator);
        return (
          signOff: id.isEmpty
              ? oneOff
              : SignOff(
                  id: id,
                  name: oneOff.name,
                  text: text,
                  separator: separator,
                  changedAt: oneOff.changedAt,
                ),
        );
      }
    } on FormatException {
      // Unreadable: find the sign-off by its text instead.
    }
    return null;
  }
}
