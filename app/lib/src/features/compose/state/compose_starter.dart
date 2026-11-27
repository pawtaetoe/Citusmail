// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../core/state/notice.dart';
import '../../../services/app_services.dart';
import '../../reader/state/reader_state.dart';

/// Starts messages in the compose window: new ones, replies, forwards,
/// and drafts opened again. The window itself is shown by [onCompose].
final class ComposeStarter {
  ComposeStarter(
    this._services, {
    required this._accountInView,
    required this._notify,
  });

  final AppServices _services;

  /// The account being viewed, if one is.
  final int? Function() _accountInView;
  final ShowNotice _notify;
  bool _disposed = false;

  MailStore get _store => _services.store;

  /// Opens the compose window (set by the screen that can show it).
  void Function(Draft draft)? onCompose;

  /// Opens [draft] in the compose window.
  void show(Draft draft) => onCompose?.call(draft);

  /// A new message from the account being viewed (or the first account).
  void compose() {
    final accountId = _accountInView() ?? _store.accounts.all().firstOrNull?.id;
    if (accountId != null) onCompose?.call(Draft(accountId: accountId));
  }

  void reply(ReaderReady r) =>
      onCompose?.call(_services.replies.reply(r.message, r.view));

  void replyAll(ReaderReady r) =>
      onCompose?.call(_services.replies.replyAll(r.message, r.view));

  void forward(ReaderReady r) =>
      onCompose?.call(_services.replies.forward(r.message, r.view));

  /// The open message exactly as the server sent it (stored when opened),
  /// or null if it is not on the device.
  Uint8List? rawMessage(StoredMessage message) =>
      _store.messages.body(message.id);

  /// Forward the whole message as an attached email.
  void forwardAsAttachment(ReaderReady r) {
    final raw = rawMessage(r.message);
    if (raw == null) return;
    onCompose?.call(_services.replies.forwardAsAttachment(r.message, raw));
  }

  /// Whether [m] is a draft in a Drafts folder (it opens in the compose
  /// window, not the reader).
  bool isDraft(StoredMessage m) =>
      m.flags.draft &&
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.drafts;

  /// Opens a draft from the Drafts folder in the compose window,
  /// downloading it first if needed.
  Future<void> editDraft(StoredMessage message) async {
    try {
      if (_store.messages.body(message.id) == null) {
        await _services.worker.loadBody(message.id);
      }
      final raw = _store.messages.body(message.id);
      if (raw == null || _disposed) return;
      onCompose?.call(_services.drafts.fromDraftsFolder(message, raw));
    } on SyncWorkerException {
      _notify('Can\'t open the draft while offline.');
    } on BodyUnavailableException {
      _notify('This draft is no longer on the server.');
    }
  }

  void dispose() => _disposed = true;
}
