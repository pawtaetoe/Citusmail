// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';

import 'mail_location.dart';

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

/// What the message list shows, loaded a page at a time. Every query reads
/// an index, so the cost depends on what is on screen, not on the size of
/// the mailbox.
final class MessageListModel extends ChangeNotifier {
  MessageListModel(this._store) {
    _collapsed = _readCollapsed();
  }

  final MailStore _store;

  /// First page of an expanded section, and each "Show more".
  static const sectionPage = 5;
  static const sectionMore = 30;

  /// Messages read to name the senders of a collapsed section.
  static const collapsedPreview = 4;
  static const flatPage = 60;

  static const _collapsedKey = 'ui.collapsedSections';

  MailLocation _location = const InboxLocation();
  bool _smart = true;
  Set<SmartSection> _collapsed = const {};

  MailLocation get location => _location;
  bool get smart => _smart;
  bool get showsSections => _location is InboxLocation && _smart;

  /// Smart Inbox: sections with mail, in order.
  List<SectionState> sections = const [];

  /// Every other view: one list.
  List<StoredMessage> messages = const [];
  bool reachedEnd = false;
  bool loadingOlder = false;

  /// Messages in the order they appear (for keyboard moves and opening the
  /// next message after one is archived).
  List<StoredMessage> get visible => showsSections
      ? [
          for (final s in sections)
            if (s.expanded) ...s.messages,
        ]
      : messages;

  void show(MailLocation location, {required bool smart}) {
    _location = location;
    _smart = smart;
    messages = const [];
    reachedEnd = false;
    refresh();
  }

  /// Re-reads what is shown, keeping how much was loaded.
  void refresh() {
    final location = _location;
    if (showsSections) {
      final counts = _store.messages.sectionCounts(
        accountIds: _accounts(location.accountId),
      );
      final previous = {for (final s in sections) s.section: s};
      sections = [
        for (final section in SmartSection.values)
          if (counts[section]!.total > 0)
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
      messages = switch (location) {
        SearchLocation(:final text) => _store.messages.search(text, limit: 200),
        OutboxLocation() => const [],
        _ => _store.messages.list(_query(location, limit: wanted)),
      };
      if (location is SearchLocation) reachedEnd = true;
    }
    notifyListeners();
  }

  SectionState _loadSection(SectionState state, SectionCount count) {
    state.count = count;
    final loaded = state.messages.length;
    final wanted = !state.expanded
        ? collapsedPreview
        : (loaded < sectionPage ? sectionPage : loaded);
    state.messages = _store.messages.list(
      MessageQuery.smart(
        state.section,
        accountIds: _accounts(_location.accountId),
        limit: wanted,
      ),
    );
    return state;
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
    final more = _store.messages.list(
      MessageQuery.smart(
        section,
        accountIds: _accounts(_location.accountId),
        before: state.messages.lastOrNull,
        limit: sectionMore,
      ),
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
    SearchLocation() || OutboxLocation() => throw StateError('not paged'),
  };

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
