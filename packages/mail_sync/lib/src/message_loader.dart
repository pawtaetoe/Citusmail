// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

/// Why a message body could not be downloaded.
enum BodyProblem {
  /// Larger than [MessageLoader.maxMessageBytes].
  tooLarge,

  /// No longer on the server (deleted or moved elsewhere).
  gone,

  /// The folder was reset on the server; a sync will rebuild it.
  folderChanged,
}

final class BodyUnavailableException implements Exception {
  const BodyUnavailableException(this.problem);

  final BodyProblem problem;

  @override
  String toString() => 'BodyUnavailableException(${problem.name})';
}

/// Downloads full messages (when opened) into the encrypted store and
/// indexes their text for search. Uses BODY.PEEK, so opening a message
/// never marks it read on the server by itself.
final class MessageLoader {
  MessageLoader(this._store, {this.maxMessageBytes = 50 * 1024 * 1024});

  final MailStore _store;

  /// Bigger messages are not downloaded whole.
  final int maxMessageBytes;

  /// The stored body of [messageId], downloading it with [imap] first if
  /// needed.
  Future<Uint8List> load(ImapClient imap, int messageId) async {
    final cached = _store.messages.body(messageId);
    if (cached != null) return cached;

    final message = _store.messages.byId(messageId);
    if (message == null) throw const BodyUnavailableException(BodyProblem.gone);
    if (message.size > maxMessageBytes) {
      throw const BodyUnavailableException(BodyProblem.tooLarge);
    }
    final mailbox = _store.mailboxes.byId(message.mailboxId);
    if (mailbox == null) throw const BodyUnavailableException(BodyProblem.gone);

    final selected = imap.selected?.name == mailbox.encodedName
        ? imap.selected!
        : await imap.select(mailbox.encodedName, readOnly: true);
    if (selected.uidValidity != mailbox.syncState.uidValidity) {
      throw const BodyUnavailableException(BodyProblem.folderChanged);
    }

    final fetched = await imap.uidFetch(
      SequenceSet.of([message.uid]),
      FetchItems(fullMessage: true),
    );
    final raw = fetched.messages
        .where((m) => m.uid == message.uid)
        .map((m) => m.sections[''])
        .nonNulls
        .firstOrNull;
    if (raw == null) throw const BodyUnavailableException(BodyProblem.gone);
    if (raw.length > maxMessageBytes) {
      throw const BodyUnavailableException(BodyProblem.tooLarge);
    }

    _store.messages.saveBody(
      messageId,
      raw,
      searchableText: MessageView.parse(raw).searchableText,
    );
    return raw;
  }
}
