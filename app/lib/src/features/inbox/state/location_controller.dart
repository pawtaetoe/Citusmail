// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'mail_location.dart';
import 'message_list_model.dart';
import 'selection_controller.dart';

/// Where the user is (the inbox, a section, a folder, a search), and
/// showing more of that list: stored mail first, then older mail from the
/// server.
final class LocationController {
  LocationController(
    this._store,
    this._worker,
    this._list,
    this._selection, {
    required this._refresh,
  });

  final MailStore _store;
  final SyncWorker _worker;
  final MessageListModel _list;
  final SelectionController _selection;

  /// Re-reads the mail screen (after a view folder synced).
  final VoidCallback _refresh;
  bool _disposed = false;

  final location = ValueNotifier<MailLocation>(const InboxLocation());

  void goTo(MailLocation target) {
    _selection.clear();
    location.value = target;
    _list.show(target);
    // Views like Gmail's Starred are not synced in the background.
    if (target case FolderLocation(:final mailboxId)
        when _store.mailboxes.byId(mailboxId)?.isView ?? false) {
      unawaited(
        _worker
            .syncFolder(mailboxId)
            .then((_) => _refresh())
            .catchError((Object _) {}),
      );
    }
  }

  void search(String text) {
    final trimmed = text.trim();
    goTo(trimmed.isEmpty ? const InboxLocation() : SearchLocation(trimmed));
  }

  /// Searches for exactly what was typed, without correcting typos.
  void searchExactly(String text) {
    final trimmed = text.trim();
    goTo(
      trimmed.isEmpty
          ? const InboxLocation()
          : SearchLocation(trimmed, exact: true),
    );
  }

  /// Shows more of a flat list: stored messages first, then older mail
  /// from the server.
  Future<void> loadMore() async {
    if (_list.loadMoreStored() || _list.loadingOlder || _list.reachedEnd) {
      return;
    }
    final folders = _foldersToExtend(location.value);
    if (folders.isEmpty) {
      _list.setLoadingOlder(false, reachedEnd: true);
      return;
    }
    _list.setLoadingOlder(true);
    var added = 0;
    var failed = false;
    try {
      for (final mailboxId in folders) {
        added += await _worker.fetchOlder(mailboxId);
      }
    } on SyncWorkerException {
      // Offline: not the end, so the next scroll tries again.
      failed = true;
    }
    if (_disposed) return;
    _list.setLoadingOlder(false, reachedEnd: !failed && added == 0);
    _list.loadMoreStored();
  }

  List<int> _foldersToExtend(MailLocation at) => switch (at) {
    FolderLocation(:final mailboxId) => [mailboxId],
    InboxLocation(:final accountId) ||
    SectionLocation(:final accountId) => _store.messages.inboxIds(
      accountIds: accountId == null ? null : [accountId],
    ),
    _ => const [],
  };

  void dispose() {
    _disposed = true;
    location.dispose();
  }
}
