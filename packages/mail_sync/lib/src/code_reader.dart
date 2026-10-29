// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

/// Finds the code in new verification mail, so the list can show it
/// without the message being opened. Most servers (Gmail, Outlook) send
/// no preview text, so fresh Codes mail is downloaded (BODY.PEEK: it stays
/// unread) from the user's own server, kept like an opened message, and
/// read on the device. Each message is read once; nothing else is
/// contacted.
final class CodeReader {
  CodeReader(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final MailStore _store;
  final DateTime Function() _now;

  /// Codes expire within minutes; older mail is not downloaded for them.
  static const maxAge = Duration(days: 1);

  /// A verification mail is a few KB; bigger ones are left alone.
  static const maxBytes = 256 * 1024;

  /// Messages read per sync, newest first.
  static const maxMessages = 10;

  /// Reads new Codes mail in the inbox of [account] over [imap]; returns
  /// how many codes were found.
  Future<int> read(ImapClient imap, Account account) async {
    final inbox = _store.mailboxes.inbox(account.id);
    if (inbox == null) return 0;
    final waiting = _store.messages.codesToRead(
      inbox.id,
      since: _now().subtract(maxAge),
      maxSize: maxBytes,
      limit: maxMessages,
    );
    if (waiting.isEmpty) return 0;
    final byUid = {for (final m in waiting) m.uid: m};
    final selected = imap.selected?.name == inbox.encodedName
        ? imap.selected!
        : await imap.select(inbox.encodedName, readOnly: true);
    if (selected.uidValidity != inbox.syncState.uidValidity) return 0;
    final fetched = await imap.uidFetch(
      SequenceSet.of(byUid.keys),
      FetchItems(fullMessage: true),
    );
    var found = 0;
    final seen = <int>{};
    for (final item in fetched.messages) {
      final message = byUid[item.uid];
      final raw = item.sections[''];
      if (message == null || raw == null || raw.length > maxBytes) continue;
      seen.add(message.id);
      final view = MessageView.parse(raw);
      final code =
          VerificationCodes.inMessage(message.subject, view.body.plainText) ??
          '';
      _store.transaction(() {
        _store.messages.saveBody(
          message.id,
          raw,
          searchableText: view.searchableText,
        );
        _store.messages.setCode(message.id, code);
      });
      if (code.isNotEmpty) found++;
    }
    // Gone from the server, or larger than it said: not asked again.
    for (final message in waiting) {
      if (!seen.contains(message.id)) _store.messages.setCode(message.id, '');
    }
    return found;
  }
}
