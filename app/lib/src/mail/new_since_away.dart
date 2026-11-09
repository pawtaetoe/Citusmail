// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import '../services/app_settings.dart';
import 'store_changes.dart';

/// The time the user was away: from when the app went to the background
/// (or closed) until they came back.
final class AwayWindow {
  const AwayWindow(this.since, this.until);

  final DateTime since;
  final DateTime until;

  /// Whether mail received at [at] arrived while the user was away.
  bool contains(DateTime at) => at.isAfter(since) && !at.isAfter(until);
}

/// What "New since you were away" shows: inbox mail from people that
/// arrived while the user was away, newest first, and how many
/// newsletters and notifications came too (those stay in their sections).
final class AwayMail {
  const AwayMail({
    this.messages = const [],
    this.since,
    this.newsletters = 0,
    this.notifications = 0,
  });

  static const none = AwayMail();

  final List<StoredMessage> messages;

  /// When the user went away (null when there is nothing to show).
  final DateTime? since;
  final int newsletters;
  final int notifications;

  bool get isEmpty => messages.isEmpty;

  Set<int> get ids => {for (final m in messages) m.id};

  int get unread => messages.where((m) => !m.flags.seen).length;
}

/// "New since you were away" at the top of the Smart Inbox.
///
/// The moment the app goes to the background (or closes) is kept in the
/// settings store, so it survives the app being closed. Coming back after
/// more than [awayFor], the mail received in between is the section's;
/// it stays put while the app is open, so the user can work through it,
/// and is rebuilt only the next time they come back. Mail that arrives
/// while the app is open goes to its usual section. Only a view: nothing
/// changes on the server.
final class NewSinceAway {
  NewSinceAway(this._store);

  final MailStore _store;

  /// When the app went away, in milliseconds since the epoch (UTC). Gone
  /// while the app is in use.
  static const awayKey = 'inbox.awaySince';

  /// Shorter absences (a look at another app) don't count.
  static const awayFor = Duration(minutes: 1);

  /// The most messages the section looks at (a long holiday).
  static const maxMessages = 300;

  /// Replaced in tests.
  static DateTime Function() clock = DateTime.now;

  /// The time the section covers; null when there is no section.
  AwayWindow? window;

  /// The app went to the background or is closing: remembers when, unless
  /// it already went earlier (and was never back since).
  void wentAway([DateTime? at]) {
    if (_store.settings.read(awayKey) != null) return;
    final when = (at ?? clock()).toUtc();
    _store.settings.write(awayKey, '${when.millisecondsSinceEpoch}');
  }

  /// The app is in front again (or started): after more than [awayFor],
  /// what arrived since the app went away is the new section. Returns
  /// whether the section changed. On the very first run nothing was
  /// stored, so there is no section.
  bool cameBack([DateTime? at]) {
    final stored = int.tryParse(_store.settings.read(awayKey) ?? '');
    _store.settings.delete(awayKey);
    if (stored == null) return false;
    final since = DateTime.fromMillisecondsSinceEpoch(stored, isUtc: true);
    final now = (at ?? clock()).toUtc();
    if (now.difference(since) <= awayFor) return false;
    window = AwayWindow(since, now);
    return true;
  }

  /// "Done": the messages go back to their sections until the next time
  /// the user comes back.
  void done() => window = null;

  /// The section's mail in the inboxes of [accountIds] (or every
  /// account): read through the inbox list index, newest first, only as
  /// far back as the user went away.
  /// Nothing while the setting is off.
  AwayMail mail({List<int>? accountIds}) {
    final window = this.window;
    if (window == null || !AppSettings(_store).newSinceAway) {
      return AwayMail.none;
    }
    // Read again only when something in the store changed.
    final key = (_changes.stamp, accountIds?.join(','), window);
    if (_last case (final k, final mail) when k == key) return mail;
    final mail = _read(window, accountIds);
    _last = (key, mail);
    return mail;
  }

  late final _changes = StoreChanges(_store);
  (((int, int), String?, AwayWindow), AwayMail)? _last;

  AwayMail _read(AwayWindow window, List<int>? accountIds) {
    final candidates = <StoredMessage>[];
    // Starts where the window ends, not at the newest mail: what came
    // after the user was back is not paged through on every refresh.
    StoredMessage? before = _endOf(window);
    while (candidates.length < maxMessages * 3) {
      final page = _store.messages.list(
        MessageQuery.inbox(accountIds: accountIds, before: before, limit: 100),
      );
      candidates.addAll(page);
      // A message is never listed before it was received.
      if (page.length < 100 || !page.last.listedAt.isAfter(window.since)) {
        break;
      }
      before = page.last;
    }
    return select(
      candidates,
      window,
      ownAddresses: {
        for (final a in _store.accounts.all()) a.email.toLowerCase(),
      },
      blocked: (address) => _store.blocks.matching(address) != null,
    );
  }

  /// A list position just after the last message listed by [window]'s
  /// end (paging continues before it).
  static StoredMessage _endOf(AwayWindow window) => StoredMessage(
    id: 1 << 62,
    mailboxId: 0,
    accountId: 0,
    uid: 1,
    receivedAt: window.until,
    size: 0,
    flags: const MessageFlags(0),
    hasAttachments: false,
    category: MessageCategory.general,
    categorySource: CategorySource.rule,
  );

  /// The messages among [inbox] that belong in the section: received
  /// while away, from someone else, not blocked or waiting in the
  /// Screener. Newsletters and notifications are only counted; Pinned and
  /// Verification keep theirs (a sign-in code is for right now).
  static AwayMail select(
    Iterable<StoredMessage> inbox,
    AwayWindow window, {
    required Set<String> ownAddresses,
    required bool Function(String address) blocked,
  }) {
    final messages = <StoredMessage>[];
    var newsletters = 0;
    var notifications = 0;
    for (final m in inbox) {
      if (!window.contains(m.receivedAt)) continue;
      final from = m.from?.address.toLowerCase();
      // Mail the user sent (to themselves, or a copy in the inbox).
      if (from != null && ownAddresses.contains(from)) continue;
      if (from != null && blocked(from)) continue;
      switch (m.section) {
        case SmartSection.important || SmartSection.general:
          if (messages.length < maxMessages) messages.add(m);
        case SmartSection.newsletters:
          newsletters++;
        case SmartSection.notifications:
          notifications++;
        case SmartSection.pinned ||
            SmartSection.codes ||
            SmartSection.screener ||
            SmartSection.snoozed:
          break;
      }
    }
    if (messages.isEmpty) return AwayMail.none;
    return AwayMail(
      messages: messages,
      since: window.since,
      newsletters: newsletters,
      notifications: notifications,
    );
  }
}
