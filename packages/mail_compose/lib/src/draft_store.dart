// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'draft.dart';
import 'outgoing.dart';

/// Where a draft ended up when the compose window closed.
enum DraftOutcome {
  /// Nothing was written; nothing kept.
  discarded,

  /// Queued for the server's Drafts folder (it goes there with the next
  /// sync, also when offline now).
  savedToServer,

  /// The account has no Drafts folder: kept on this device.
  keptOnDevice,
}

/// Drafts while they are written (saved on the device every few seconds)
/// and after (moved to the server's Drafts folder).
final class DraftStore {
  DraftStore(this._store, {this.messages = const OutgoingMessages()});

  final MailStore _store;
  final OutgoingMessages messages;

  /// Saves [draft] on the device and returns it with its id.
  Draft save(Draft draft) {
    final id = _store.drafts.save(
      id: draft.id,
      accountId: draft.accountId,
      content: draft.encodeContent(),
      savedMessageId: draft.savedMessageId,
      attachments: [
        for (final a in draft.attachments)
          StoredDraftAttachment(
            fileName: a.fileName,
            mimeType: a.mimeType,
            data: a.bytes,
          ),
      ],
    );
    return draft.copyWith(id: id);
  }

  Draft? load(int id) {
    final stored = _store.drafts.byId(id);
    if (stored == null) return null;
    return Draft.decodeContent(
      stored.content,
      id: stored.id,
      accountId: stored.accountId,
      savedMessageId: stored.savedMessageId,
      attachments: [
        for (final a in _store.drafts.attachments(id))
          DraftAttachment(
            fileName: a.fileName,
            mimeType: a.mimeType,
            bytes: a.data,
          ),
      ],
    );
  }

  /// Drafts still on the device (normally none: a draft is moved to the
  /// server when its window closes, so these are left from a crash).
  List<Draft> onDevice() => [
    for (final stored in _store.drafts.all()) ?load(stored.id),
  ];

  /// The compose window closed: an empty draft is dropped (with its older
  /// server copy); anything else goes to the server's Drafts folder,
  /// replacing its older copy there.
  DraftOutcome close(Draft draft) {
    if (draft.isEmpty) {
      discard(draft);
      return DraftOutcome.discarded;
    }
    final account = _store.accounts.byId(draft.accountId);
    final folder = account == null
        ? null
        : _store.mailboxes.bySpecialUse(account.id, SpecialUse.drafts);
    if (account == null || folder == null) {
      save(draft);
      return DraftOutcome.keptOnDevice;
    }
    final built = messages.forDraftsFolder(draft, account);
    _store.transaction(() {
      // New copy first, then remove the old one: a failure in between
      // leaves two copies, never none.
      _store.outbox.enqueue(
        account.id,
        AppendAction(mailboxId: folder.id, flags: const [r'\Draft', r'\Seen']),
        data: built.bytes,
      );
      _removeServerCopy(account.id, folder, draft.savedMessageId);
      if (draft.id case final id?) _store.drafts.delete(id);
    });
    return DraftOutcome.savedToServer;
  }

  /// Throws the draft away, on the device and in the Drafts folder.
  void discard(Draft draft) => _store.transaction(() {
    if (draft.id case final id?) _store.drafts.delete(id);
    final folder = _store.mailboxes.bySpecialUse(
      draft.accountId,
      SpecialUse.drafts,
    );
    if (folder != null) {
      _removeServerCopy(draft.accountId, folder, draft.savedMessageId);
    }
  });

  /// Moves every draft left on the device to the server (after a crash).
  int moveLeftoversToServer() {
    var moved = 0;
    for (final draft in onDevice()) {
      if (close(draft) == DraftOutcome.savedToServer) moved++;
    }
    return moved;
  }

  /// A message from the Drafts folder, to continue writing it. The copy in
  /// the folder is replaced when the draft is saved or sent.
  Draft fromDraftsFolder(StoredMessage message, Uint8List raw) {
    final view = MessageView.parse(raw);
    final parsed = view.message;
    return Draft(
      accountId: message.accountId,
      to: parsed.to,
      cc: parsed.cc,
      bcc: parsed.bcc,
      subject: parsed.subject ?? '',
      body: view.isHtml
          ? view.body.plainText
          : (parsed.textBody?.decodeText().text ?? ''),
      attachments: [
        for (final a in view.attachments)
          DraftAttachment(
            fileName: a.fileName,
            mimeType: a.mimeType,
            bytes: a.bytes(),
          ),
      ],
      inReplyTo: parsed.inReplyTo.firstOrNull,
      references: parsed.references,
      savedMessageId: parsed.messageId ?? message.messageId,
    );
  }

  /// Queues removal of the folder copy [messageId] and hides it from the
  /// local cache at once (the server confirms on the next sync).
  void _removeServerCopy(
    int accountId,
    StoredMailbox folder,
    String? messageId,
  ) {
    if (messageId == null || messageId.isEmpty) return;
    final RemoveDraftAction action;
    try {
      action = RemoveDraftAction(mailboxId: folder.id, messageId: messageId);
    } on ArgumentError {
      return; // not an id we could have written; leave it alone
    }
    _store.outbox.enqueue(accountId, action);
    final cached = _store.messages
        .list(MessageQuery(mailboxIds: [folder.id], limit: 500))
        .where((m) => m.messageId == messageId && m.flags.draft)
        .map((m) => m.uid)
        .toList();
    if (cached.isNotEmpty) _store.messages.removeUids(folder.id, cached);
  }
}
