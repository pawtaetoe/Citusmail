// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// Reads read receipts (RFC 8098 reports) that arrived in the inbox and
/// records them for the sent messages that asked for one. Receipts for
/// anything else are ignored. Each report is read once.
final class ReceiptCollector {
  const ReceiptCollector(this._store);

  final MailStore _store;

  /// Reports larger than this are not read (a receipt is a few KB).
  static const maxReportBytes = 256 * 1024;

  /// Reads new reports of [account] over [imap]; returns how many
  /// receipts were recorded.
  Future<int> collect(ImapClient imap, Account account) async {
    final inbox = _store.mailboxes.inbox(account.id);
    if (inbox == null) return 0;
    final ids = _store.receipts.unreadReports(inbox.id);
    if (ids.isEmpty) return 0;
    final byUid = <int, StoredMessage>{};
    for (final id in ids) {
      final message = _store.messages.byId(id);
      if (message == null) continue;
      if (message.size > maxReportBytes) {
        _store.receipts.markReportRead(id); // not a plausible receipt
      } else {
        byUid[message.uid] = message;
      }
    }
    if (byUid.isEmpty) return 0;
    await imap.select(inbox.encodedName, readOnly: true);
    final fetched = await imap.uidFetch(
      SequenceSet.of(byUid.keys),
      FetchItems(fullMessage: true),
    );
    var recorded = 0;
    for (final item in fetched.messages) {
      final message = byUid[item.uid];
      final raw = item.sections[''];
      if (message == null || raw == null) continue;
      final notice = DispositionNotification.fromMessage(
        const MimeParser().parse(raw),
      );
      if (notice != null) {
        final original = notice.originalMessageId;
        if (!_store.receipts.wasRequested(account.id, original) &&
            _askedFromAnotherDevice(account, original)) {
          _store.receipts.requested(account.id, original);
        }
        if (_store.receipts.record(
          account.id,
          original,
          recipient: notice.finalRecipient,
          disposition: notice.disposition,
          at: message.receivedAt,
        )) {
          recorded++;
        }
      }
      _store.receipts.markReportRead(message.id);
    }
    return recorded;
  }

  /// Whether the sent copy of [messageId] asked for receipts (it was
  /// written on another of the user's devices).
  bool _askedFromAnotherDevice(Account account, String messageId) {
    final sent = _store.mailboxes.bySpecialUse(account.id, SpecialUse.sent);
    if (sent == null) return false;
    return _store.messages
        .byMessageId(sent.id, messageId)
        .any(
          (m) => _store.messages
              .headers(m.id)
              .containsKey('disposition-notification-to'),
        );
  }
}
