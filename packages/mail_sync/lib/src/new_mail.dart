// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

/// Finds mail worth a notification, exactly once.
///
/// Each account keeps a mark: the highest inbox UID already considered
/// (with the inbox's UIDVALIDITY). [claim] reads and moves the mark in one
/// write transaction, so when the app and a background job both sync, a
/// message is announced by only one of them.
///
/// Only unread mail in the Pinned, Codes, Important and General sections
/// counts (codes are waited for), and Notifications (service mail such as
/// GitHub, a bank or a delivery) unless the user turned that off
/// ([notificationsKey]); newsletters, blocked senders, mail waiting in
/// the Screener (or screened out) and read receipts (left out of the
/// sections, see `SectionSql.readReceipt`) never interrupt. The first
/// claim of an account (or after its inbox was reset) only sets the mark,
/// so adding an account does not announce its whole inbox.
final class NewMailTracker {
  NewMailTracker(this._store);

  final MailStore _store;

  static const _sections = [
    SmartSection.pinned,
    SmartSection.codes,
    SmartSection.important,
    SmartSection.general,
  ];

  /// Off leaves the Notifications section out (on by default).
  static const notificationsSection = BoolSetting(
    'notify.notificationsSection',
    fallback: true,
  );

  List<SmartSection> get _announced => [
    ..._sections,
    if (notificationsSection.read(_store.settings)) SmartSection.notifications,
  ];

  /// At most this many are returned (the rest are counted in [NewMail]).
  static const maxMessages = 20;

  /// Where the inbox was when new mail was last claimed, per account:
  /// `UIDVALIDITY:UID`.
  static StringSetting _mark(int accountId) =>
      StringSetting('notify.mark.$accountId');

  NewMail claim(int accountId) => _store.transaction(() {
    final inbox = _store.mailboxes.inbox(accountId);
    final validity = inbox?.syncState.uidValidity;
    if (inbox == null || validity == null) return NewMail.none;
    final highest = _store.messages.highestUid(inbox.id) ?? 0;
    final mark = _readMark(accountId);
    _mark(accountId).write(_store.settings, '$validity:$highest');
    if (mark == null || mark.validity != validity || highest <= mark.uid) {
      return NewMail.none;
    }
    final fresh = <StoredMessage>[
      for (final section in _announced)
        for (final m in _store.messages.list(
          MessageQuery.smart(section, accountIds: [accountId], limit: 200),
        ))
          if (m.uid > mark.uid &&
              m.mailboxId == inbox.id &&
              !m.flags.seen &&
              // Normally already moved to Junk; never announced anyway.
              _store.blocks.matching(m.from?.address) == null)
            m,
    ]..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    return NewMail(
      accountId,
      fresh.length > maxMessages
          ? fresh.sublist(fresh.length - maxMessages)
          : fresh,
      total: fresh.length,
    );
  });

  ({int validity, int uid})? _readMark(int accountId) {
    final value = _mark(accountId).readOrNull(_store.settings);
    final parts = value?.split(':');
    if (parts == null || parts.length != 2) return null;
    final validity = int.tryParse(parts[0]);
    final uid = int.tryParse(parts[1]);
    if (validity == null || uid == null) return null;
    return (validity: validity, uid: uid);
  }
}

/// New mail of one account to announce, oldest first.
final class NewMail {
  const NewMail(this.accountId, this.messages, {required this.total});

  static const none = NewMail(0, [], total: 0);

  final int accountId;
  final List<StoredMessage> messages;

  /// All new messages, including any beyond [messages].
  final int total;

  bool get isEmpty => total == 0;
}
