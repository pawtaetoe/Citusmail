// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// Recipient suggestions for one message being written: everyone who can
/// be suggested is read once (at the first suggestion), then typed text
/// is matched in memory, so a key press never scans the mailbox.
final class AddressBook {
  AddressBook(this._load);

  /// Everyone who can be suggested, the best first.
  final List<MailAddress> Function() _load;

  List<(MailAddress, String)>? _entries;

  /// At most [limit] addresses with [text] in the address or the name
  /// (any case), the best first.
  List<MailAddress> suggest(String text, {int limit = 8}) {
    final typed = text.trim().toLowerCase();
    if (typed.isEmpty) return const [];
    final entries = _entries ??= [
      for (final a in _load())
        (a, '${a.address}\n${a.displayName ?? ''}'.toLowerCase()),
    ];
    final found = <MailAddress>[];
    for (final (address, words) in entries) {
      if (!words.contains(typed)) continue;
      found.add(address);
      if (found.length == limit) break;
    }
    return found;
  }
}
