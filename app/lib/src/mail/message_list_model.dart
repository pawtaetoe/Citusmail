// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'mail_location.dart';
import 'new_since_away.dart';
import 'store_changes.dart';

/// One Smart Inbox section in the accordion.
final class SectionState {
  SectionState(this.section, {required this.expanded});

  final SmartSection section;
  SectionCount count = SectionCount.empty;
  bool expanded;

  /// Loaded messages, newest first (a few for a collapsed section, to name
  /// their senders).
  List<StoredMessage> messages = const [];

  bool get hasMore => messages.length < count.total;
}

/// A follow-up with its sent message, when that is on the device.
final class FollowUpRow {
  const FollowUpRow(this.followUp, this.message);

  final FollowUp followUp;
  final StoredMessage? message;
}

/// What the message list shows, loaded a page at a time. Every query reads
/// an index, so the cost depends on what is on screen, not on the size of
/// the mailbox.
final class MessageListModel extends ChangeNotifier {
  MessageListModel(this._store) : away = NewSinceAway(_store) {
    _collapsed = _readCollapsed();
  }

  final MailStore _store;

  /// When the user was away, for "New since you were away".
  final NewSinceAway away;

  /// First page of an expanded section, and each "Show more".
  static const sectionPage = 5;
  static const sectionMore = 30;

  /// Messages read to name the senders of a collapsed section.
  static const collapsedPreview = 4;
  static const flatPage = 60;

  static const _collapsedKey = 'ui.collapsedSections';

  MailLocation _location = const InboxLocation();
  Set<SmartSection> _collapsed = const {};

  MailLocation get location => _location;

  /// The inbox is always the Smart Inbox: sections instead of one list.
  bool get showsSections => _location is InboxLocation;

  /// Smart Inbox: sections with mail, in order.
  List<SectionState> sections = const [];

  /// Smart Inbox: first-time senders waiting in the Screener.
  int screenerWaiting = 0;

  /// Smart Inbox: "New since you were away", at the very top. While it is
  /// there, its messages are not in their usual sections.
  AwayMail newSinceAway = AwayMail.none;
  Set<int> _awayIds = const {};

  /// How many of [newSinceAway] show before "Show all".
  static const awayPage = 8;
  bool _awayShowAll = false;

  /// The messages of [newSinceAway] on screen.
  List<StoredMessage> get awayShown =>
      _awayShowAll || newSinceAway.messages.length <= awayPage
      ? newSinceAway.messages
      : newSinceAway.messages.sublist(0, awayPage);

  void showAllAway() {
    _awayShowAll = true;
    notifyListeners();
  }

  /// Whether [m] is in "New since you were away" (not its usual section).
  bool isAway(StoredMessage m) => _awayIds.contains(m.id);

  /// Smart Inbox: sent mail back with "No reply yet", at the top. Waiting
  /// for a reply: every follow-up, those back first.
  List<FollowUpRow> followUps = const [];

  /// Every other view: one list.
  List<StoredMessage> messages = const [];

  /// Snoozed: when each message comes back, by Message-ID.
  Map<String, DateTime> snoozedUntil = const {};
  bool reachedEnd = false;
  bool loadingOlder = false;

  /// Messages in the order they appear (for keyboard moves and opening the
  /// next message after one is archived).
  List<StoredMessage> get visible => showsSections
      ? [
          ...awayShown,
          for (final f in followUps) ?f.message,
          for (final s in sections)
            if (s.expanded) ...s.messages,
        ]
      : location is FollowUpsLocation
      ? [for (final f in followUps) ?f.message]
      : messages;

  void show(MailLocation location) {
    _location = location;
    messages = const [];
    reachedEnd = false;
    refresh();
  }

  /// Re-reads what is shown, keeping how much was loaded.
  void refresh() {
    final location = _location;
    followUps = switch (location) {
      InboxLocation(:final accountId) => _followUps(
        returnedOnly: true,
        accountId: accountId,
      ),
      FollowUpsLocation() => _followUps(),
      _ => const [],
    };
    newSinceAway = showsSections
        ? away.mail(accountIds: _accounts(location.accountId))
        : AwayMail.none;
    _awayIds = newSinceAway.ids;
    if (newSinceAway.isEmpty) _awayShowAll = false;
    if (showsSections) {
      final counts = _withoutAway(sectionCounts(accountId: location.accountId));
      screenerWaiting = _store.screener.waitingCount(
        accountIds: _accounts(location.accountId),
      );
      final previous = {for (final s in sections) s.section: s};
      sections = [
        for (final section in SmartSection.values)
          // Waiting senders have their own entry (Screener), and snoozed
          // mail its own list (Snoozed): neither is a section.
          if (section != SmartSection.screener &&
              section != SmartSection.snoozed &&
              counts[section]!.total > 0)
            _loadSection(
              previous[section] ??
                  SectionState(
                    section,
                    expanded: !_collapsed.contains(section),
                  ),
              counts[section]!,
            ),
      ];
    } else {
      final wanted = messages.length < flatPage ? flatPage : messages.length;
      final snoozed = location is SnoozedLocation
          ? _store.snoozes.list()
          : const <SnoozedMessage>[];
      snoozedUntil = {
        for (final s in snoozed) s.snooze.messageId: s.snooze.until,
      };
      messages = switch (location) {
        SearchLocation(:final text) => _store.messages.search(text, limit: 200),
        OutboxLocation() || FollowUpsLocation() => const [],
        SnoozedLocation() => [for (final s in snoozed) s.message],
        _ => _store.messages.list(_query(location, limit: wanted)),
      };
      if (location is SearchLocation ||
          location is SnoozedLocation ||
          location is FollowUpsLocation) {
        reachedEnd = true;
      }
    }
    notifyListeners();
  }

  SectionState _loadSection(SectionState state, SectionCount count) {
    state.count = count;
    final loaded = state.messages.length;
    final wanted = !state.expanded
        ? collapsedPreview
        : (loaded < sectionPage ? sectionPage : loaded);
    state.messages = _listSection(state.section, limit: wanted);
    return state;
  }

  /// A page of [section], without the messages in "New since you were
  /// away".
  List<StoredMessage> _listSection(
    SmartSection section, {
    StoredMessage? before,
    required int limit,
  }) {
    final away = newSinceAway.messages.where((m) => m.section == section);
    final page = _store.messages.list(
      MessageQuery.smart(
        section,
        accountIds: _accounts(_location.accountId),
        before: before,
        limit: limit + away.length,
      ),
    );
    if (away.isEmpty) return page;
    return page.where((m) => !_awayIds.contains(m.id)).take(limit).toList();
  }

  /// Section counts without the messages in "New since you were away".
  Map<SmartSection, SectionCount> _withoutAway(
    Map<SmartSection, SectionCount> counts,
  ) {
    if (newSinceAway.isEmpty) return counts;
    SectionCount without(SmartSection section, SectionCount count) {
      final moved = [
        for (final m in newSinceAway.messages)
          if (m.section == section) m,
      ];
      return SectionCount(
        count.total - moved.length,
        count.unread - moved.where((m) => !m.flags.seen).length,
      );
    }

    return {
      for (final MapEntry(key: section, value: count) in counts.entries)
        section: without(section, count),
    };
  }

  /// Opens or closes a section; remembered across restarts.
  void toggleSection(SmartSection section) {
    final state = sections.where((s) => s.section == section).firstOrNull;
    if (state == null) return;
    state.expanded = !state.expanded;
    _collapsed = {
      for (final s in sections)
        if (!s.expanded) s.section,
      // Keep sections that are empty now as they were.
      for (final c in _collapsed)
        if (!sections.any((s) => s.section == c)) c,
    };
    _store.settings.write(
      _collapsedKey,
      _collapsed.map((s) => s.name).join(','),
    );
    _loadSection(state, state.count);
    notifyListeners();
  }

  void showMoreInSection(SmartSection section) {
    final state = sections.where((s) => s.section == section).firstOrNull;
    if (state == null || !state.hasMore) return;
    final more = _listSection(
      section,
      before: state.messages.lastOrNull,
      limit: sectionMore,
    );
    state.messages = [...state.messages, ...more];
    notifyListeners();
  }

  /// The next page of stored messages; false if there are none (the caller
  /// may then fetch older mail from the server).
  bool loadMoreStored() {
    if (reachedEnd || messages.isEmpty || showsSections) return false;
    final page = _store.messages.list(_query(_location, before: messages.last));
    if (page.isEmpty) return false;
    messages = [...messages, ...page];
    notifyListeners();
    return true;
  }

  void setLoadingOlder(bool loading, {bool reachedEnd = false}) {
    loadingOlder = loading;
    if (reachedEnd) this.reachedEnd = true;
    notifyListeners();
  }

  MessageQuery _query(
    MailLocation location, {
    StoredMessage? before,
    int limit = flatPage,
  }) => switch (location) {
    InboxLocation(:final accountId) => MessageQuery.inbox(
      accountIds: _accounts(accountId),
      before: before,
      limit: limit,
    ),
    SectionLocation(:final section, :final accountId) => MessageQuery.smart(
      section,
      accountIds: _accounts(accountId),
      before: before,
      limit: limit,
    ),
    FolderLocation(:final mailboxId) => MessageQuery(
      mailboxIds: [mailboxId],
      before: before,
      limit: limit,
    ),
    PinsLocation() => MessageQuery(
      flaggedOnly: true,
      before: before,
      limit: limit,
    ),
    SearchLocation() ||
    OutboxLocation() ||
    SnoozedLocation() ||
    FollowUpsLocation() => throw StateError('not paged'),
  };

  /// Follow-ups (of [accountId], or every account) with their sent
  /// messages: those back with "No reply yet" first, most recent first,
  /// then the ones waiting, soonest due first.
  List<FollowUpRow> _followUps({bool returnedOnly = false, int? accountId}) {
    final reminders = FollowUpReminders(_store);
    return [
      for (final f in [
        ...reminders.returned(),
        if (!returnedOnly) ...reminders.waiting(),
      ])
        if (accountId == null || f.accountId == accountId)
          FollowUpRow(f, reminders.sentCopy(f)),
    ];
  }

  late final _changes = StoreChanges(_store);
  (int, int)? _countsStamp;
  final _counts = <int?, Map<SmartSection, SectionCount>>{};

  /// The Smart Inbox section counts of [accountId] (or every account),
  /// counted again only when something in the store changed since.
  Map<SmartSection, SectionCount> sectionCounts({int? accountId}) {
    final stamp = _changes.stamp;
    if (stamp != _countsStamp) {
      _counts.clear();
      _countsStamp = stamp;
    }
    return _counts[accountId] ??= _store.messages.sectionCounts(
      accountIds: _accounts(accountId),
    );
  }

  static List<int>? _accounts(int? accountId) =>
      accountId == null ? null : [accountId];

  Set<SmartSection> _readCollapsed() {
    final stored = _store.settings.read(_collapsedKey);
    if (stored == null) {
      // First run: the inbox opens on what needs attention.
      return const {SmartSection.notifications, SmartSection.newsletters};
    }
    return {
      for (final name in stored.split(','))
        ?SmartSection.values.asNameMap()[name],
    };
  }
}
