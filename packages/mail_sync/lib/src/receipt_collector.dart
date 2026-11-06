// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

/// Reads read receipts (RFC 8098 reports) that arrived in the inbox and
/// records them for the sent messages that asked for one, entirely on the
/// device. Receipts for anything else are ignored. Each report is read
/// once.
///
/// The sent message is found by the report's `In-Reply-To`, then its
/// `References` (newest first), then the `Original-Message-ID` in the
/// report itself: the first one that names a message the user asked a
/// receipt for (from this device, or from another one: its copy in Sent
/// carries `Disposition-Notification-To`).
///
/// A report's few KB are read from the device when it is already there
/// (opened, or read ahead); otherwise it is downloaded from the user's
/// own server with BODY.PEEK (it stays unread) and kept like an opened
/// message, so it opens instantly from the sent message.
final class ReceiptCollector {
  const ReceiptCollector(this._store);

  final MailStore _store;

  /// Reports larger than this are not read (a receipt is a few KB).
  static const maxReportBytes = 256 * 1024;

  /// Reports read per sync, newest first; the rest wait for the next one.
  static const maxReports = 50;

  /// Bumped when matching improves, so reports read before are read once
  /// more (2: thread headers, a missing Original-Message-ID, links to the
  /// report).
  static const matcherVersion = 2;

  static String _versionKey(int accountId) => 'receipts.matcher.$accountId';

  /// Reads new reports of [account], over [imap] for those not on the
  /// device yet; returns how many receipts were recorded.
  Future<int> collect(ImapClient imap, Account account) async {
    final inbox = _store.mailboxes.inbox(account.id);
    if (inbox == null) return 0;
    var recorded = readStored(account);
    final byUid = <int, StoredMessage>{};
    for (final id in _store.receipts.unreadReports(
      inbox.id,
      limit: maxReports,
    )) {
      final message = _store.messages.byId(id);
      if (message == null) continue;
      if (message.size > maxReportBytes) {
        _store.receipts.markReportRead(id); // not a plausible receipt
      } else {
        byUid[message.uid] = message;
      }
    }
    if (byUid.isEmpty) return recorded;
    final selected = imap.selected?.name == inbox.encodedName
        ? imap.selected!
        : await imap.select(inbox.encodedName, readOnly: true);
    if (selected.uidValidity != inbox.syncState.uidValidity) return recorded;
    final fetched = await imap.uidFetch(
      SequenceSet.of(byUid.keys),
      FetchItems(fullMessage: true),
    );
    for (final item in fetched.messages) {
      final message = byUid[item.uid];
      final raw = item.sections[''];
      if (message == null || raw == null) continue;
      if (raw.length > maxReportBytes) {
        _store.receipts.markReportRead(message.id);
        continue;
      }
      _store.messages.saveBody(
        message.id,
        raw,
        searchableText: MessageView.parse(raw).searchableText,
      );
      if (read(account, message, raw) != null) recorded++;
    }
    return recorded;
  }

  /// Reads the new reports of [account] that are already on the device
  /// (opened, or read ahead); returns how many receipts were recorded.
  int readStored(Account account) {
    final inbox = _store.mailboxes.inbox(account.id);
    if (inbox == null) return 0;
    _upgrade(account, inbox);
    var recorded = 0;
    for (final id in _store.receipts.unreadReports(inbox.id, limit: 500)) {
      final raw = _store.messages.body(id);
      final message = raw == null ? null : _store.messages.byId(id);
      if (raw != null &&
          message != null &&
          read(account, message, raw) != null) {
        recorded++;
      }
    }
    return recorded;
  }

  /// Reads one [report] of [account] (its full message [raw]) and records
  /// the receipt for the sent message it is about. Returns that message's
  /// Message-ID, or null when nothing was recorded: not a receipt, not
  /// about mail that asked for one, or `denied` / `failed` (old kinds
  /// that are not receipts at all). The report is not read again.
  String? read(Account account, StoredMessage report, Uint8List raw) {
    try {
      final notice = DispositionNotification.fromMessage(
        const MimeParser().parse(raw),
      );
      if (notice == null) return null;
      final original = _sentMessage(account, report, notice);
      if (original == null) return null;
      final recorded = _store.receipts.record(
        account.id,
        original,
        recipient: notice.finalRecipient,
        disposition: notice.disposition,
        at: readAt(report),
      );
      if (!recorded) return null;
      _store.receipts.linkReport(
        account.id,
        original,
        recipient: notice.finalRecipient,
        reportId: report.id,
      );
      return original;
    } on FormatException {
      return null;
    } finally {
      _store.receipts.markReportRead(report.id);
    }
  }

  /// When the receipt says it was read: its Date, unless that is later
  /// than when it arrived (a wrong clock), else when it arrived.
  static DateTime readAt(StoredMessage report) {
    final date = report.sentAt;
    return date != null &&
            !date.isAfter(report.receivedAt.add(const Duration(hours: 1)))
        ? date
        : report.receivedAt;
  }

  /// The Message-ID of the user's message [report] is about, if it asked
  /// for a receipt.
  String? _sentMessage(
    Account account,
    StoredMessage report,
    DispositionNotification notice,
  ) {
    final candidates = [
      ?report.inReplyTo,
      ...report.references.reversed,
      ?notice.originalMessageId,
    ];
    for (final id in candidates) {
      if (_store.receipts.wasRequested(account.id, id)) return id;
      if (_askedFromAnotherDevice(account, id)) {
        _store.receipts.requested(account.id, id);
        return id;
      }
    }
    return null;
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

  /// Reports read by an older version are read once more.
  void _upgrade(Account account, StoredMailbox inbox) {
    final key = _versionKey(account.id);
    if (_store.settings.read(key) == '$matcherVersion') return;
    _store.receipts.rereadReports(inbox.id);
    _store.settings.write(key, '$matcherVersion');
  }
}
