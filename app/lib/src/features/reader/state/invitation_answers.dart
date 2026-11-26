// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

/// The user's answers to invitations, remembered on the device per event
/// version (UID and SEQUENCE), so the card can say "You accepted". Kept
/// in the settings store; the oldest are forgotten past [limit].
final class InvitationAnswers {
  InvitationAnswers(this._store);

  final MailStore _store;

  static const key = 'invitations.answers';
  static const limit = 500;

  Map<String, String> _read() {
    try {
      final decoded = jsonDecode(_store.settings.read(key) ?? '{}');
      if (decoded is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String && value is String) key: value,
      };
    } on FormatException {
      return {};
    }
  }

  /// What the user answered to this version of [invite], if anything.
  CalendarAnswer? of(CalendarInvite invite) =>
      CalendarAnswer.parse(_read()[invite.answerKey]);

  void remember(CalendarInvite invite, CalendarAnswer answer) {
    final all = _read()
      ..remove(invite.answerKey)
      ..[invite.answerKey] = answer.token; // newest last
    final kept = all.entries.skip(all.length > limit ? all.length - limit : 0);
    _store.settings.write(key, jsonEncode(Map.fromEntries(kept)));
  }

  /// Forgets the answer (it was undone); [previous] is restored if given.
  void forget(CalendarInvite invite, {CalendarAnswer? previous}) {
    final all = _read()..remove(invite.answerKey);
    if (previous != null) all[invite.answerKey] = previous.token;
    _store.settings.write(key, jsonEncode(all));
  }
}
