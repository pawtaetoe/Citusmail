// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'message_list_model.dart';
import 'store_changes.dart';

/// Counts for the sidebar and section headers, read together.
final class MailCounts {
  const MailCounts({
    required this.sections,
    required this.perAccountUnread,
    required this.folderUnread,
    required this.outbox,
    this.snoozed = 0,
    this.followUps = 0,
    this.pins = 0,
  });

  static const empty = MailCounts(
    sections: {},
    perAccountUnread: {},
    folderUnread: {},
    outbox: 0,
  );

  /// Messages snoozed in the inboxes.
  final int snoozed;

  /// Sent messages waiting for a reply ("Remind me if no reply"),
  /// including those back with "No reply yet".
  final int followUps;

  /// Pinned mail in every folder (the Pins list), not only the Inbox's.
  final int pins;

  final Map<SmartSection, SectionCount> sections;
  final Map<AccountId, int> perAccountUnread;
  final Map<MailboxId, int> folderUnread;
  final int outbox;

  /// Unread mail in the Smart Inbox (mail waiting in the Screener isn't
  /// counted until its sender is let in, nor snoozed mail until it comes
  /// back).
  int get inboxUnread => unreadIn(sections);

  /// Whether [other] counts the same: then nothing needs showing again.
  bool same(MailCounts other) =>
      identical(this, other) ||
      (snoozed == other.snoozed &&
          pins == other.pins &&
          followUps == other.followUps &&
          outbox == other.outbox &&
          mapEquals(perAccountUnread, other.perAccountUnread) &&
          mapEquals(folderUnread, other.folderUnread) &&
          sections.length == other.sections.length &&
          sections.entries.every(
            (e) =>
                other.sections[e.key]?.total == e.value.total &&
                other.sections[e.key]?.unread == e.value.unread,
          ));

  static int unreadIn(Map<SmartSection, SectionCount> sections) => [
    for (final MapEntry(:key, :value) in sections.entries)
      if (key != SmartSection.screener && key != SmartSection.snoozed)
        value.unread,
  ].fold(0, (sum, n) => sum + n);
}

/// Keeps [counts] up to date. Counts are read again only when something
/// in the store changed since the last look.
final class CountsController {
  CountsController(this._store, this._list, this._followUps)
    : _changes = StoreChanges(_store);

  final MailStore _store;
  final MessageListModel _list;
  final FollowUpReminders _followUps;
  final StoreChanges _changes;
  (int, int)? _stamp;

  final counts = ValueNotifier<MailCounts>(MailCounts.empty);

  /// Counts again, if anything in the store changed.
  void refresh() {
    final stamp = _changes.stamp;
    if (stamp == _stamp) return;
    _stamp = stamp;
    final accounts = _store.accounts.all();
    final sections = _list.sectionCounts();
    final fresh = MailCounts(
      sections: sections,
      perAccountUnread: {
        for (final a in accounts)
          a.id: MailCounts.unreadIn(
            accounts.length == 1
                ? sections
                : _list.sectionCounts(accountId: a.id),
          ),
      },
      folderUnread: _store.messages.unreadCounts(),
      outbox: _store.outbox.sends().length,
      snoozed: _store.snoozes.count(),
      followUps: _followUps.all().length,
      pins: _store.messages.pinnedCount(),
    );
    // The sync worker writes after every check, mostly without changing
    // any count: the sidebar is built again only when one changed.
    if (!fresh.same(counts.value)) counts.value = fresh;
  }

  void dispose() => counts.dispose();
}
