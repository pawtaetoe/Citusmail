// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'mailbox_synchronizer.dart';

/// Keeps mail archived elsewhere on the device.
///
/// Gmail's All Mail repeats every other folder, so it is not synced in the
/// background ([StoredMailbox.isView]) and nothing is stored twice. But
/// archived Gmail mail is *only* in All Mail: when a message leaves the
/// inbox on another device, it would leave this device too, and no longer
/// turn up in search. So the Message-IDs of messages that leave an
/// ordinary folder are noted, and on the next full sync those that are in
/// no other stored folder are looked up in All Mail, and their summaries
/// stored there. Mail deleted for good is not in All Mail, and is simply
/// not found.
final class ArchivedMail {
  ArchivedMail(this._store, this._mailboxSync);

  final MailStore _store;
  final MailboxSynchronizer _mailboxSync;

  /// Most messages looked up per full sync; the rest wait for the next.
  static const maxPerSync = 50;

  /// Most noted messages kept waiting.
  static const maxWaiting = 500;

  static String _key(int accountId) => 'sync.archived.$accountId';

  /// Notes what [results] removed from the account's ordinary folders
  /// (not All Mail, Starred, Important, Trash or Junk), when it has an
  /// All Mail folder.
  void note(Account account, Map<int, MailboxSyncResult> results) {
    if (_allMail(account) == null) return;
    final ids = <String>[];
    for (final MapEntry(key: mailboxId, value: result) in results.entries) {
      if (result.removedMessageIds.isEmpty) continue;
      final use = _store.mailboxes.byId(mailboxId)?.specialUse;
      if (use != null &&
          (StoredMailbox.copyUses.contains(use.name) ||
              use == SpecialUse.trash ||
              use == SpecialUse.junk)) {
        continue;
      }
      ids.addAll(result.removedMessageIds);
    }
    if (ids.isEmpty) return;
    _write(account, {..._waiting(account), ...ids}.toList());
  }

  /// Looks the waiting messages up in All Mail over [imap] and stores
  /// those found. Returns how many were stored.
  Future<int> find(ImapClient imap, Account account) async {
    final allMail = _allMail(account);
    final waiting = _waiting(account);
    if (allMail == null || waiting.isEmpty) {
      if (waiting.isNotEmpty) _store.settings.delete(_key(account.id));
      return 0;
    }
    final ordinary = [
      for (final m in _store.mailboxes.forAccount(account.id))
        if (m.id == allMail.id || !m.isView) m,
    ];
    final later = waiting.skip(maxPerSync).toList();
    // Moved to another folder, or already there: nothing to look up.
    final now = [
      for (final id in waiting.take(maxPerSync))
        if (!ordinary.any(
          (m) => _store.messages.byMessageId(m.id, id).isNotEmpty,
        ))
          id,
    ];
    if (now.isEmpty) {
      _write(account, later);
      return 0;
    }
    final selected = await imap.select(allMail.encodedName, readOnly: true);
    final known = allMail.syncState.uidValidity;
    if (known != null && known != selected.uidValidity) {
      // The folder was reset: opening it syncs it afresh anyway.
      _store.settings.delete(_key(account.id));
      return 0;
    }
    final uids = <int>{};
    for (final id in now) {
      uids.addAll(
        (await imap.uidSearch(SearchCriteria.header('Message-ID', '<$id>')))
            .matches
            .toList(),
      );
    }
    final stored = uids.isEmpty
        ? 0
        : await _mailboxSync.fetchUids(imap, allMail, (uids.toList()..sort()));
    _write(account, later);
    return stored;
  }

  StoredMailbox? _allMail(Account account) {
    final folder = _store.mailboxes.bySpecialUse(account.id, SpecialUse.all);
    return folder != null && folder.selectable ? folder : null;
  }

  List<String> _waiting(Account account) {
    final text = _store.settings.read(_key(account.id));
    if (text == null) return const [];
    try {
      return [
        for (final id in jsonDecode(text) as List<Object?>) id! as String,
      ];
    } on Object {
      return const [];
    }
  }

  void _write(Account account, List<String> ids) {
    if (ids.isEmpty) {
      _store.settings.delete(_key(account.id));
      return;
    }
    final kept = ids.length > maxWaiting
        ? ids.sublist(ids.length - maxWaiting)
        : ids;
    _store.settings.write(_key(account.id), jsonEncode(kept));
  }
}
