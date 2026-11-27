// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart' show VerificationCodes;
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_view/mail_view.dart';

import '../../../services/app_services.dart';
import '../../compose/state/compose_starter.dart';
import '../../inbox/state/mail_counts.dart';
import '../../inbox/state/message_list_model.dart';
import 'reader_state.dart';

/// The open message: opening it (read, downloaded and checked), moving to
/// the next one, its images, and keeping it fresh after changes. Drafts
/// open in the compose window instead ([ComposeStarter]).
final class ReaderController {
  ReaderController(
    this._services,
    this._list,
    this._counts,
    this._compose, {
    required this._refresh,
  });

  final AppServices _services;
  final MessageListModel _list;
  final CountsController _counts;
  final ComposeStarter _compose;

  /// Re-reads the mail screen (after a code is found in a message).
  final VoidCallback _refresh;
  bool _disposed = false;

  /// Whether the screen has closed (nothing may be shown any more).
  bool get disposed => _disposed;

  MailStore get _store => _services.store;

  final reader = ValueNotifier<ReaderState>(const ReaderEmpty());

  StoredMessage? get selected => reader.value.message;

  /// Opens [message]: marks it read and shows it, downloading it first if
  /// needed. Drafts open in the compose window instead.
  Future<void> open(StoredMessage message) async {
    if (_compose.isDraft(message)) return _compose.editDraft(message);
    if (!message.flags.seen) {
      _services.actions.markRead([message]);
      _services.worker.requestSync(message.accountId);
      message = _store.messages.byId(message.id) ?? message;
      _list.refresh();
      _counts.refresh();
    }
    reader.value = ReaderLoading(message);
    try {
      final ready = await readerFor(message);
      if (_disposed || selected?.id != message.id) return;
      reader.value = ready;
    } on BodyUnavailableException catch (e) {
      if (_disposed || selected?.id != message.id) return;
      reader.value = ReaderFailed(message, switch (e.problem) {
        BodyProblem.tooLarge => 'This message is too large to show.',
        BodyProblem.gone => 'This message is no longer on the server.',
        BodyProblem.folderChanged =>
          'The folder changed on the server. Try again after the next sync.',
      });
    } on SyncWorkerException catch (e) {
      if (_disposed || selected?.id != message.id) return;
      reader.value = ReaderFailed(message, switch (e.failure.kind) {
        SyncFailureKind.network =>
          'Can\'t reach the server. The message opens once you\'re online.',
        SyncFailureKind.authentication =>
          _store.accounts.byId(message.accountId)?.usesOAuth ?? false
              ? 'The sign-in has ended. Sign in again from the account menu.'
              : 'The server didn\'t accept your password.',
        SyncFailureKind.security =>
          'The connection was refused for security reasons.',
        SyncFailureKind.server =>
          'The server had a problem: ${e.failure.message}',
      });
    }
  }

  /// [message] read and checked, as the reading pane shows it, without
  /// opening it (it stays unread): downloads it first if needed. Throws
  /// [BodyUnavailableException] or [SyncWorkerException].
  Future<ReaderReady> readerFor(StoredMessage message) async {
    if (_store.messages.body(message.id) == null) {
      await _services.worker.loadBody(message.id);
    }
    final raw = _store.messages.body(message.id);
    if (raw == null) throw const BodyUnavailableException(BodyProblem.gone);
    // Parsing and checking a large message must not block the UI.
    final (view, trust, plan) = await compute(_parseAndCheck, (
      raw,
      _trustContext(message),
    ));
    _findCode(message, view);
    return ReaderReady(
      _store.messages.byId(message.id) ?? message,
      view,
      to: _store.messages.addresses(message.id, 'to'),
      cc: _store.messages.addresses(message.id, 'cc'),
      trust: trust,
      unsubscribe: plan,
      unsubscribed: unsubscriptionFor(message),
      imagesShown:
          trust.level != TrustLevel.danger &&
          trust.verified &&
          _store.imageSenders.isAllowed(message.from?.address),
    );
  }

  /// A verification email opened before its code was found (older mail
  /// the code reader hasn't reached): the code is read now, so the list
  /// shows it from here on.
  void _findCode(StoredMessage message, MessageView view) {
    if (message.category != MessageCategory.codes) return;
    if (message.code?.isNotEmpty ?? false) return;
    final code = VerificationCodes.inMessage(
      message.subject,
      view.body.plainText,
    );
    if (code == null) return;
    _store.messages.setCode(message.id, code);
    _refresh();
  }

  /// What identifies [message]'s list (List-Id, else the sender).
  static String? listKey(StoredMessage message) => Unsubscription.listKeyOf(
    listId: message.listId,
    fromAddress: message.from?.address,
  );

  /// When the user unsubscribed from [message]'s list, if they did.
  Unsubscription? unsubscriptionFor(StoredMessage message) {
    final key = listKey(message);
    return key == null
        ? null
        : _store.unsubscriptions.find(message.accountId, key);
  }

  /// What the message checks need besides the message: which server's
  /// verification results to believe, learned from the account's recent
  /// inbox mail, and the user's own domains. Null for the user's own
  /// mail (Sent, Drafts), which needs no checking.
  TrustContext? _trustContext(StoredMessage message) {
    final use = _store.mailboxes.byId(message.mailboxId)?.specialUse;
    if (use == SpecialUse.sent || use == SpecialUse.drafts) return null;
    final inbox = _store.mailboxes.inbox(message.accountId);
    final account = _store.accounts.byId(message.accountId);
    return TrustContext(
      trustedAuthServId: inbox == null
          ? null
          : AuthServIds.learn(
              _store.messages.firstHeaderValues(
                inbox.id,
                'authentication-results',
              ),
              serverHosts: {?account?.imap.host},
            ),
      ownDomains: {
        for (final account in _store.accounts.all())
          ?Domains.registrable(
            account.email.substring(account.email.lastIndexOf('@') + 1),
          ),
      },
    );
  }

  void close() => reader.value = const ReaderEmpty();

  /// Loads the open message's images; with [always], also for later mail
  /// from this sender (only offered when the server verified the sender).
  void showImages(ReaderReady r, {bool always = false}) {
    if (!r.imagesAllowed) return;
    final from = r.message.from?.address;
    if (always && r.trust.verified && from != null) {
      try {
        _store.imageSenders.allow(from);
      } on ArgumentError {
        // An address that can't be stored: load this time only.
      }
    }
    if (reader.value case final ReaderReady open
        when open.message.id == r.message.id) {
      reader.value = open.copyWith(imagesShown: true);
    }
  }

  /// Opens the message after (or before) the open one in the list.
  void openNext({bool previous = false}) {
    final visible = _list.visible;
    if (visible.isEmpty) return;
    final index = visible.indexWhere((m) => m.id == selected?.id);
    final next = index < 0
        ? 0
        : (previous ? index - 1 : index + 1).clamp(0, visible.length - 1);
    if (next != index) unawaited(open(visible[next]));
  }

  /// Reads the open message again from the store (its flags, its
  /// section); closes it if it is gone.
  void refreshOpen() {
    final current = selected;
    if (current == null) return;
    final fresh = _store.messages.byId(current.id);
    if (fresh == null) {
      reader.value = const ReaderEmpty();
      return;
    }
    reader.value = switch (reader.value) {
      ReaderLoading() => ReaderLoading(fresh),
      final ReaderReady ready => ready.copyWith(message: fresh),
      ReaderFailed(:final reason) => ReaderFailed(fresh, reason),
      ReaderEmpty() => const ReaderEmpty(),
    };
  }

  /// For the user's own mail that asked for read receipts: the receipts
  /// so far (maybe none). Null when it didn't ask.
  List<ReadReceipt>? receiptsFor(StoredMessage message) {
    final id = message.messageId;
    if (id == null) return null;
    final account = _store.accounts.byId(message.accountId);
    final own =
        account != null &&
        message.from?.address.toLowerCase() == account.email.toLowerCase();
    if (!own) return null;
    final asked =
        _store.receipts.wasRequested(message.accountId, id) ||
        _store.messages
            .headers(message.id)
            .containsKey('disposition-notification-to');
    if (!asked) return null;
    return _store.receipts.forMessage(message.accountId, id);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    reader.dispose();
  }
}

/// Top level, so [compute] sends only the bytes to the helper isolate.
(MessageView, TrustReport, UnsubscribePlan) _parseAndCheck(
  (Uint8List, TrustContext?) input,
) {
  final (raw, context) = input;
  final view = MessageView.parse(raw);
  final trust = context == null
      ? TrustReport.empty
      : const TrustChecker().check(view, context);
  return (view, trust, UnsubscribePlanner.plan(view.message, trust));
}
