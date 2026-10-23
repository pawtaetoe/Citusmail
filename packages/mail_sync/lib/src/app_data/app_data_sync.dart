// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import '../folder_rules.dart';
import 'snapshotter.dart';

/// Where the sync code comes from (the system keychain, or the UI isolate
/// asking it). Null when sync is off.
abstract interface class SyncCodeProvider {
  Future<String?> syncCode();
}

/// The last exchange, as kept in the store for the settings screen.
final class AppDataSyncStatus {
  const AppDataSyncStatus({
    required this.at,
    required this.devices,
    required this.unreadable,
    this.problem,
  });

  final DateTime at;

  /// Devices whose data was read (this one included).
  final int devices;
  final int unreadable;

  /// Why the last try failed (it then says when it failed).
  final String? problem;
}

/// What one exchange did.
final class AppDataSyncReport {
  AppDataSyncReport({
    required this.devices,
    required this.changes,
    required this.published,
    required this.unreadable,
  });

  /// Devices whose data was read (this one included).
  final int devices;
  final AppliedChanges changes;

  /// Whether this device stored a new snapshot.
  final bool published;

  /// Stored snapshots of this code that couldn't be opened (damaged).
  final int unreadable;
}

/// Exchanges app data with the user's other devices through a folder in
/// the sync account.
///
/// Each device keeps exactly one message in the folder: its sealed
/// snapshot (see `mail_appsync`). An exchange reads the others', merges
/// everything, applies the result here, and replaces this device's
/// message if what it knows changed. Devices never write each other's
/// messages, so two of them syncing at once can't overwrite one another.
final class AppDataSync {
  AppDataSync(this._store, this._codes, {DateTime Function()? now})
    : _snapshotter = AppDataSnapshotter(_store),
      _now = now ?? DateTime.now;

  final MailStore _store;
  final SyncCodeProvider _codes;
  final AppDataSnapshotter _snapshotter;
  final DateTime Function() _now;

  static const syncHeader = 'X-Citusmail-Sync';
  static const deviceHeader = 'X-Citusmail-Device';
  static const attachmentName = 'citusmail-sync.bin';

  /// Most snapshot messages read in one exchange.
  static const maxMessages = 50;

  static const _accountSetting = 'sync.account';
  static const _publishedSetting = 'sync.published';
  static const _statusSetting = 'sync.status';

  /// The account whose mailbox carries the data: the one chosen, else the
  /// first account.
  Account? get account => accountIn(_store);

  /// [account], for code without an [AppDataSync] (the settings screen).
  static Account? accountIn(MailStore store) {
    final all = store.accounts.all();
    final chosen = int.tryParse(store.settings.read(_accountSetting) ?? '');
    return all.where((a) => a.id == chosen).firstOrNull ?? all.firstOrNull;
  }

  static void chooseAccount(MailStore store, Account account) =>
      store.settings.write(_accountSetting, '${account.id}');

  /// How the last exchange went, or null if none happened yet.
  static AppDataSyncStatus? statusIn(MailStore store) {
    final text = store.settings.read(_statusSetting);
    if (text == null) return null;
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      return AppDataSyncStatus(
        at: DateTime.fromMillisecondsSinceEpoch(
          json['at']! as int,
          isUtc: true,
        ),
        devices: json['devices'] as int? ?? 0,
        unreadable: json['unreadable'] as int? ?? 0,
        problem: json['problem'] as String?,
      );
    } on Object {
      return null;
    }
  }

  /// Records a failed exchange (the sync of mail itself went on).
  void recordProblem(String problem) => _store.settings.write(
    _statusSetting,
    jsonEncode({
      'at': _now().toUtc().millisecondsSinceEpoch,
      'devices': statusIn(_store)?.devices ?? 0,
      'unreadable': 0,
      'problem': problem,
    }),
  );

  /// Exchanges data over [imap], a logged-in connection of [syncAccount].
  /// Returns null when sync is off or this isn't the sync account.
  Future<AppDataSyncReport?> run(ImapClient imap, Account syncAccount) async {
    if (syncAccount.id != account?.id) return null;
    final text = await _codes.syncCode();
    final code = text == null ? null : SyncCode.parse(text);
    if (code == null) return null;
    final keys = code.keys;
    final sealer = SnapshotSealer(keys);
    final me = _snapshotter.device;

    final folder = await _folder(imap, syncAccount);
    await imap.select(folder);

    // Everyone's snapshots for this code (ours included).
    final found = (await imap.uidSearch(
      SearchCriteria.header(syncHeader, keys.syncId),
    )).matches.toList()..sort();
    final uids = found.length > maxMessages
        ? found.sublist(found.length - maxMessages)
        : found;
    final remote = <String, SyncSnapshot>{};
    final ours = <int>[];
    var unreadable = 0;
    if (uids.isNotEmpty) {
      final fetched = await imap.uidFetch(
        SequenceSet.of(uids),
        FetchItems(fullMessage: true),
      );
      for (final message in fetched.messages) {
        final raw = message.sections[''];
        final uid = message.uid;
        if (raw == null || uid == null) continue;
        final parsed = _parse(raw, keys.syncId);
        if (parsed == null) {
          unreadable++;
          continue;
        }
        final (device, bytes) = parsed;
        if (device == me) {
          ours.add(uid);
          continue; // this device's own state is what's in the store
        }
        try {
          final snapshot = sealer.open(bytes, device: device);
          final previous = remote[device];
          if (previous == null || snapshot.createdAt > previous.createdAt) {
            remote[device] = snapshot;
          }
        } on AuthenticationFailed {
          unreadable++;
        } on FormatException {
          unreadable++;
        }
      }
    }

    final now = _now().toUtc().millisecondsSinceEpoch;
    final local = _snapshotter.localRecords();
    final merged = SyncSnapshot.merge([
      SyncSnapshot(device: me, createdAt: now, records: local.values.toList()),
      ...remote.values,
    ]);
    final changes = _snapshotter.apply(merged);

    // Publish when what this device knows differs from what it last
    // stored, or its message is gone.
    final records = merged.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final fingerprint = '${keys.syncId}:${_fingerprint(records)}';
    var published = false;
    if (ours.isEmpty ||
        _store.settings.read(_publishedSetting) != fingerprint) {
      final snapshot = SyncSnapshot(
        device: me,
        createdAt: now,
        records: records,
      );
      await imap.append(
        folder,
        _message(syncAccount, keys.syncId, me, sealer.seal(snapshot)),
        flags: const {r'\Seen'},
      );
      await _remove(imap, ours);
      _store.settings.write(_publishedSetting, fingerprint);
      published = true;
    }
    // This device's messages from an earlier code are of no use now. (The
    // search runs again: the snapshot just stored is current, not stale.)
    final current = (await imap.uidSearch(
      SearchCriteria.header(syncHeader, keys.syncId),
    )).matches.toList().toSet();
    final mine = (await imap.uidSearch(SearchCriteria.header(deviceHeader, me)))
        .matches
        .toList();
    await _remove(imap, [
      for (final uid in mine)
        if (!current.contains(uid)) uid,
    ]);

    _store.settings.write(
      _statusSetting,
      jsonEncode({
        'at': now,
        'devices': remote.length + 1,
        'unreadable': unreadable,
      }),
    );
    return AppDataSyncReport(
      devices: remote.length + 1,
      changes: changes,
      published: published,
      unreadable: unreadable,
    );
  }

  /// Removes this device's stored data from the folder (sync turned off
  /// here). Other devices keep theirs.
  Future<void> forget(ImapClient imap, Account syncAccount) async {
    final folder = _store.mailboxes
        .forAccount(syncAccount.id)
        .where((m) => m.isAppData)
        .firstOrNull;
    if (folder != null) {
      await imap.select(folder.encodedName);
      final mine = await imap.uidSearch(
        SearchCriteria.header(deviceHeader, _snapshotter.device),
      );
      await _remove(imap, mine.matches.toList());
    }
    _store.settings.delete(_publishedSetting);
    _store.settings.delete(_statusSetting);
    _store.appDataSync.reset();
  }

  /// The data folder's server name, created if missing.
  Future<String> _folder(ImapClient imap, Account account) async {
    final existing = _store.mailboxes
        .forAccount(account.id)
        .where((m) => m.isAppData)
        .firstOrNull;
    if (existing != null) return existing.encodedName;
    final encoded = FolderNames.newFolder(
      _store.mailboxes.forAccount(account.id),
      StoredMailbox.appDataName,
    );
    await imap.create(encoded); // an existing folder counts as created
    _store.mailboxes.replaceAll(account.id, await imap.listMailboxes());
    return encoded;
  }

  Future<void> _remove(ImapClient imap, List<int> uids) async {
    if (uids.isEmpty) return;
    final set = SequenceSet.of(uids);
    await imap.uidStore(set, FlagChange.add, {r'\Deleted'});
    // Only these messages: other devices' stay.
    await imap.uidExpunge(set);
  }

  /// The device id and sealed bytes in a stored message, or null if it
  /// isn't one of this code's snapshots.
  static (String, Uint8List)? _parse(Uint8List raw, String syncId) {
    final message = const MimeParser().parse(raw);
    if (message.headers.value(syncHeader)?.trim() != syncId) return null;
    final device = message.headers.value(deviceHeader)?.trim();
    if (device == null || !RegExp(r'^[0-9a-f]{8,64}$').hasMatch(device)) {
      return null;
    }
    for (final part in message.attachments) {
      if (part.filename == attachmentName) {
        return (device, part.decodeBody().bytes);
      }
    }
    return null;
  }

  /// A message holding [sealed]: a short note for anyone who opens the
  /// folder in another mail app, and the data as an attachment.
  Uint8List _message(
    Account account,
    String syncId,
    String device,
    Uint8List sealed,
  ) {
    final at = account.email.lastIndexOf('@');
    final self = MailAddress(
      localPart: account.email.substring(0, at),
      domain: account.email.substring(at + 1),
    );
    final built = MessageBuilder().build(
      OutgoingMessage(
        from: self,
        to: [self],
        subject: 'Citusmail sync data - please keep',
        textBody:
            'Citusmail keeps your settings the same on all your devices with '
            'this message. Its content is encrypted; only your devices can '
            'read it. Deleting it only makes your devices exchange the data '
            'again.\n',
        attachments: [
          OutgoingAttachment(
            filename: attachmentName,
            mimeType: 'application/octet-stream',
            bytes: sealed,
          ),
        ],
      ),
    );
    return Uint8List.fromList([
      ...ascii.encode('$syncHeader: $syncId\r\n$deviceHeader: $device\r\n'),
      ...built.bytes,
    ]);
  }

  static String _fingerprint(List<SyncRecord> records) => sha256
      .convert(utf8.encode(jsonEncode([for (final r in records) r.toJson()])))
      .toString();
}
