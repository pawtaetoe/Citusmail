// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'mailbox_synchronizer.dart';

/// Searches an account's mail on its server, for what search on the
/// device does not find (mail older than [KeepMail] keeps, or archived
/// Gmail mail not filled in yet).
///
/// On Gmail (`X-GM-EXT-1`) it asks Gmail's own search (`X-GM-RAW`) in All
/// Mail, which has everything but spam and trash; elsewhere every word in
/// the text (`TEXT`, headers and body) in the inbox and the Archive
/// folder. The server searches: nothing but the summaries of what it
/// finds is downloaded, and those are stored like synced mail (in All
/// Mail on Gmail, as [ArchivedMail] does), so they open, pin and show in
/// Found like any other.
final class ServerSearch {
  ServerSearch(this._store, this._mailboxSync);

  final MailStore _store;
  final MailboxSynchronizer _mailboxSync;

  /// Most messages a search returns per account, newest first.
  static const maxResults = 50;

  /// Searches [account] for [text] over [imap]. Returns the stored
  /// messages it found (those already on the device too), newest first.
  Future<List<MessageId>> search(
    ImapClient imap,
    Account account,
    String text,
  ) async {
    final words = text.trim().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return const [];
    final allMail = _store.mailboxes.bySpecialUse(account.id, SpecialUse.all);
    final gmail =
        imap.capabilities.has('X-GM-EXT-1') &&
        allMail != null &&
        allMail.selectable;
    final folders = gmail
        ? [allMail]
        : [
            for (final m in [
              _store.mailboxes.inbox(account.id),
              _store.mailboxes.bySpecialUse(account.id, SpecialUse.archive),
            ])
              if (m != null && m.selectable) m,
          ];
    final criteria = gmail
        ? SearchCriteria.gmailRaw(words.join(' '))
        : SearchCriteria.and([for (final w in words) SearchCriteria.text(w)]);
    final ordinary = [
      for (final m in _store.mailboxes.forAccount(account.id))
        if (!m.isView || m.id == allMail?.id) m,
    ];

    final found = <_Found>[];
    for (final folder in folders) {
      final SelectedMailbox selected;
      try {
        selected = await imap.select(folder.encodedName, readOnly: true);
      } on ImapCommandException {
        continue; // gone on the server: noticed by the next sync
      }
      final known = folder.syncState.uidValidity;
      // Reset on the server: its next sync starts it over.
      if (known != null && known != selected.uidValidity) continue;
      final uids = (await imap.uidSearch(criteria)).matches.toList()..sort();
      final newest = uids.reversed.take(maxResults).toList();
      final unknown = <int>[];
      for (final uid in newest) {
        if (_store.messages.byUid(folder.id, uid) case final m?) {
          found.add(_Found.stored(m));
        } else {
          unknown.add(uid);
        }
      }
      // The date and Message-ID of the rest: a few bytes each.
      for (var i = 0; i < unknown.length; i += 100) {
        final part = unknown.sublist(i, (i + 100).clamp(0, unknown.length));
        final fetched = await imap.uidFetch(
          SequenceSet.of(part),
          FetchItems(internalDate: true, headerFields: const ['Message-ID']),
        );
        for (final m in fetched.messages) {
          final uid = m.uid;
          final date = m.internalDate;
          if (uid == null || date == null) continue;
          final id = _messageId(m.headerFields);
          // On the device in another folder already (the inbox, a label).
          final copy = id == null
              ? null
              : [
                  for (final f in ordinary)
                    ..._store.messages.byMessageId(f.id, id),
                ].firstOrNull;
          found.add(
            copy != null
                ? _Found.stored(copy)
                : _Found.onServer(folder, uid, date),
          );
        }
      }
    }

    found.sort((a, b) => b.date.compareTo(a.date));
    final chosen = found.take(maxResults).toList();
    // Stored, a folder at a time.
    final byFolder = <StoredMailbox, List<int>>{};
    for (final f in chosen) {
      if (f.folder case final folder?) {
        byFolder.putIfAbsent(folder, () => []).add(f.uid!);
      }
    }
    for (final MapEntry(key: folder, value: uids) in byFolder.entries) {
      if (imap.selected?.name != folder.encodedName) {
        await imap.select(folder.encodedName, readOnly: true);
      }
      await _mailboxSync.fetchUids(imap, folder, uids..sort());
    }
    final ids = <MessageId>{};
    for (final f in chosen) {
      final id = f.messageId ?? _store.messages.byUid(f.folder!.id, f.uid!)?.id;
      if (id != null) ids.add(id);
    }
    return ids.toList();
  }

  static String? _messageId(Uint8List? raw) {
    if (raw == null || raw.isEmpty) return null;
    final value = const HeaderParser().parse(raw).headers.value('message-id');
    return value == null ? null : const MessageIds().parseSingle(value);
  }
}

/// A message the search found: on the device ([messageId]) or only on
/// the server ([folder] and [uid]).
final class _Found {
  _Found.stored(StoredMessage message)
    : messageId = message.id,
      date = message.receivedAt,
      folder = null,
      uid = null;

  _Found.onServer(StoredMailbox this.folder, int this.uid, this.date)
    : messageId = null;

  final MessageId? messageId;
  final StoredMailbox? folder;
  final int? uid;
  final DateTime date;
}
