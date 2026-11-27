// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';

import '../../../core/state/notice.dart';
import '../../../services/app_services.dart';
import '../../inbox/state/message_actions.dart';
import '../../reader/state/reader_controller.dart';
import '../../reader/state/reader_state.dart';

/// Unsubscribing from the open message's list (one click, an email or a
/// web page), remembering it, and archiving the list's earlier mail.
final class UnsubscribeController {
  UnsubscribeController(
    this._services,
    this._reader,
    this._actions, {
    required this._notify,
  });

  final AppServices _services;
  final ReaderController _reader;
  final MessageActions _actions;
  final ShowNotice _notify;

  MailStore get _store => _services.store;

  /// Inbox mail from the same list as [r] (to offer archiving it).
  List<StoredMessage> sameList(ReaderReady r) => _store.messages.inboxFromList(
    r.message.accountId,
    listId: r.message.listId,
    fromAddress: r.message.listId == null ? r.message.from?.address : null,
  );

  /// Unsubscribes with [method]. One-click requests go out now; an email
  /// goes through the outbox (so it also works offline). For a web page
  /// the caller opens it and then calls this to remember it. Returns null
  /// on success, or why it failed.
  Future<String?> unsubscribe(
    ReaderReady r,
    UnsubscribeMethod method, {
    bool archiveList = false,
  }) async {
    final problem = switch (method) {
      OneClickMethod(:final url) => await _oneClick(url),
      EmailMethod(:final request) => _unsubscribeEmail(r, request),
      WebPageMethod() => null,
    };
    if (problem != null) return problem;
    final kind = switch (method) {
      OneClickMethod() => UnsubscribeKind.oneClick,
      EmailMethod() => UnsubscribeKind.email,
      WebPageMethod() => UnsubscribeKind.webPage,
    };
    final key = ReaderController.listKey(r.message);
    if (key != null) {
      final record = _store.unsubscriptions.record(
        accountId: r.message.accountId,
        listKey: key,
        listName: r.unsubscribe.listName,
        kind: kind,
      );
      // The one-click request may have outlived the screen: the
      // unsubscription is kept, but there is nothing left to show it on.
      if (_reader.disposed) return null;
      final reader = _reader.reader;
      if (reader.value case final ReaderReady open
          when open.message.id == r.message.id) {
        reader.value = open.copyWith(unsubscribed: record);
      }
    }
    if (_reader.disposed) return null;
    final name = r.unsubscribe.listName;
    final done = switch (kind) {
      UnsubscribeKind.webPage => 'Opened the unsubscribe page for $name',
      UnsubscribeKind.email => 'Unsubscribe email to $name is on its way',
      UnsubscribeKind.oneClick => 'Unsubscribed from $name',
    };
    final earlier = archiveList ? sameList(r) : const <StoredMessage>[];
    if (earlier.isNotEmpty) {
      _actions.archive(earlier, done: '$done. Archived ${earlier.length}.');
    } else {
      _notify(done);
    }
    return null;
  }

  /// Null on success, or why it failed.
  Future<String?> _oneClick(Uri url) async =>
      switch (await _services.oneClick.unsubscribe(url)) {
        OneClickDone() => null,
        OneClickFailed(:final reason) => reason,
      };

  /// Queues the email; null on success, or why it can't be sent.
  String? _unsubscribeEmail(ReaderReady r, MailtoRequest request) {
    final at = request.address.lastIndexOf('@');
    try {
      final pending = _services.sender.send(
        Draft(
          accountId: r.message.accountId,
          to: [
            MailAddress(
              localPart: request.address.substring(0, at),
              domain: request.address.substring(at + 1),
            ),
          ],
          subject: request.subject ?? 'unsubscribe',
          body: request.body ?? 'unsubscribe',
        ),
      );
      _services.worker.syncAt(pending.accountId, pending.undoUntil);
      return null;
    } on ComposeException {
      return 'Couldn\'t write the unsubscribe email: its address isn\'t usable.';
    }
  }
}
