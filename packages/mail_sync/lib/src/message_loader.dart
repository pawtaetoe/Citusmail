// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
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
    if (cached != null) {
      findCode(messageId, cached);
      return cached;
    }

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

    final view = MessageView.parse(raw);
    _store.messages.saveBody(
      messageId,
      raw,
      searchableText: view.searchableText,
    );
    findCode(messageId, raw, view: view);
    if (message.hasAttachments) {
      // The reader's list of files, for the attachments page.
      _store.messages.setHeader(messageId, FilePart.storedHeader, [
        for (final f in FilePart.listFromView(view)) f.encode(),
      ]);
    }
    return raw;
  }

  /// A verification email opened without its code found yet (older mail
  /// the code reader skips): the code is read from [raw] now, so the list
  /// shows it from here on.
  void findCode(int messageId, Uint8List raw, {MessageView? view}) {
    final message = _store.messages.byId(messageId);
    if (message == null ||
        message.category != MessageCategory.codes ||
        (message.code?.isNotEmpty ?? false)) {
      return;
    }
    final text = (view ?? MessageView.parse(raw)).body.plainText;
    final code = VerificationCodes.inMessage(message.subject, text);
    if (code != null) _store.messages.setCode(messageId, code);
  }
}

/// Looks up which files messages have, from the server's BODYSTRUCTURE
/// (a few hundred bytes a message; nothing is downloaded and nothing is
/// marked read), for mail synced before the app kept that.
final class FileLookup {
  FileLookup(this._store);

  final MailStore _store;

  /// UIDs asked from the server at once.
  static const _batch = 200;

  /// Records the files of [messageIds] (all of one account) as
  /// [FilePart.storedHeader]. Messages that are gone are skipped.
  Future<void> lookUp(ImapClient imap, List<int> messageIds) async {
    final byFolder = <int, Map<int, StoredMessage>>{};
    for (final id in messageIds) {
      final m = _store.messages.byId(id);
      if (m != null) byFolder.putIfAbsent(m.mailboxId, () => {})[m.uid] = m;
    }
    for (final MapEntry(key: mailboxId, value: byUid) in byFolder.entries) {
      final mailbox = _store.mailboxes.byId(mailboxId);
      if (mailbox == null) continue;
      final selected = imap.selected?.name == mailbox.encodedName
          ? imap.selected!
          : await imap.select(mailbox.encodedName, readOnly: true);
      if (selected.uidValidity != mailbox.syncState.uidValidity) continue;
      final uids = byUid.keys.toList();
      for (var i = 0; i < uids.length; i += _batch) {
        final fetched = await imap.uidFetch(
          SequenceSet.of(uids.sublist(i, (i + _batch).clamp(0, uids.length))),
          FetchItems(bodyStructure: true),
        );
        for (final f in fetched.messages) {
          final message = byUid[f.uid];
          final structure = f.bodyStructure;
          if (message == null || structure == null) continue;
          _store.messages.setHeader(message.id, FilePart.storedHeader, [
            for (final file in FilePart.listFromImap(structure)) file.encode(),
          ]);
        }
      }
    }
  }
}
