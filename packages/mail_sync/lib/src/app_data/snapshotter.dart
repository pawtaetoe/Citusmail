// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_store/mail_store.dart';

/// What applying the merged state changed on this device.
final class AppliedChanges {
  int added = 0;
  int removed = 0;

  /// Records this device can't use (an account or folder it doesn't
  /// have). They are kept and passed on, never lost.
  int skipped = 0;

  bool get any => added + removed > 0;

  @override
  String toString() => 'AppliedChanges(+$added -$removed ~$skipped)';
}

/// Turns this device's app data into sync records and back.
///
/// Accounts and folders are named by email address and folder name, since
/// local ids differ between devices. Times are kept exactly, so applying
/// another device's data never makes it look newer than it is.
final class AppDataSnapshotter {
  AppDataSnapshotter(this._store);

  final MailStore _store;

  String get device => _store.appDataSync.deviceId;

  /// Everything this device knows: its live data, its removals, and the
  /// last merged state of all devices (which also holds data it can't
  /// apply itself).
  Map<String, SyncRecord> localRecords() {
    final out = <String, SyncRecord>{};
    void put(SyncRecord record) {
      final current = out[record.key];
      out[record.key] = current == null
          ? record
          : SyncRecord.newer(current, record);
    }

    for (final json in _store.appDataSync.mergedState().values) {
      try {
        put(SyncRecord.fromJson(jsonDecode(json)));
      } on FormatException {
        // A damaged cache entry: other devices still have it.
      }
    }
    final me = device;
    for (final b in _store.blocks.all()) {
      put(
        SyncRecord(
          key: AppDataKeys.block(b.kind, b.value),
          kind: RecordKind.block,
          changedAt: b.since.millisecondsSinceEpoch,
          device: me,
          data: {'kind': b.kind.name, 'value': b.value},
        ),
      );
    }
    for (final s in _store.imageSenders.all()) {
      put(
        SyncRecord(
          key: AppDataKeys.imageSender(s.address),
          kind: RecordKind.imageSender,
          changedAt: s.since.millisecondsSinceEpoch,
          device: me,
          data: {'address': s.address},
        ),
      );
    }
    for (final account in _store.accounts.all()) {
      for (final u in _store.unsubscriptions.forAccount(account.id)) {
        put(
          SyncRecord(
            key: AppDataKeys.unsubscribe(account.email, u.listKey),
            kind: RecordKind.unsubscribe,
            changedAt: u.at.millisecondsSinceEpoch,
            device: me,
            data: {
              'account': account.email.toLowerCase(),
              'listKey': u.listKey,
              'listName': u.listName,
              'how': u.kind.name,
            },
          ),
        );
      }
      for (final r in _store.folderRules.forAccount(account.id)) {
        final folder = _store.mailboxes.byId(r.mailboxId);
        if (folder == null) continue;
        put(
          SyncRecord(
            key: AppDataKeys.folderRule(
              account.email,
              folder.encodedName,
              r.field,
              r.value,
            ),
            kind: RecordKind.folderRule,
            changedAt: r.createdAt.millisecondsSinceEpoch,
            device: me,
            data: {
              'account': account.email.toLowerCase(),
              'folder': folder.encodedName,
              'field': r.field.name,
              'value': r.value,
              'appliesFrom': r.appliesFrom.millisecondsSinceEpoch,
            },
          ),
        );
      }
    }
    for (final t in _store.appDataSync.tombstones()) {
      final kind = RecordKind.values.where((k) => k.name == t.kind).firstOrNull;
      if (kind == null) continue;
      put(
        SyncRecord(
          key: t.key,
          kind: kind,
          changedAt: t.deletedAt.millisecondsSinceEpoch,
          device: t.device,
          deleted: true,
        ),
      );
    }
    return out;
  }

  /// Makes this device's data match [merged], and remembers [merged].
  AppliedChanges apply(Map<String, SyncRecord> merged) =>
      _store.transaction(() {
        final changes = AppliedChanges();
        for (final record in merged.values) {
          try {
            _apply(record, changes);
          } on ArgumentError {
            changes.skipped++; // data this device can't hold
          } on FormatException {
            changes.skipped++;
          }
        }
        _store.appDataSync.replaceMergedState({
          for (final r in merged.values) r.key: jsonEncode(r.toJson()),
        });
        return changes;
      });

  void _apply(SyncRecord r, AppliedChanges changes) {
    final at = DateTime.fromMillisecondsSinceEpoch(r.changedAt, isUtc: true);
    switch (r.kind) {
      case RecordKind.block:
        final (kind, value) = _blockOf(r);
        final existing = _store.blocks.all().where(
          (b) => b.kind == kind && b.value == value,
        );
        if (r.deleted) {
          for (final b in existing.toList()) {
            _store.blocks.unblock(b.id, at: at, device: r.device);
            changes.removed++;
          }
        } else if (existing.isEmpty) {
          _store.blocks.block(kind, value, now: at);
          changes.added++;
        }
      case RecordKind.imageSender:
        final address = r.deleted ? _keyPart(r.key, 0) : _text(r, 'address');
        final existing = _store.imageSenders.all().where(
          (s) => s.address == address,
        );
        if (r.deleted) {
          for (final s in existing.toList()) {
            _store.imageSenders.remove(s.id, at: at, device: r.device);
            changes.removed++;
          }
        } else if (existing.isEmpty) {
          _store.imageSenders.allow(address, now: at);
          changes.added++;
        }
      case RecordKind.unsubscribe:
        final email = r.deleted ? _keyPart(r.key, 0) : _text(r, 'account');
        final listKey = r.deleted ? _keyPart(r.key, 1) : _text(r, 'listKey');
        final account = _account(email);
        if (account == null) {
          changes.skipped++;
          return;
        }
        final existing = _store.unsubscriptions.find(account.id, listKey);
        if (r.deleted) {
          if (existing != null) {
            _store.unsubscriptions.remove(
              existing.id,
              at: at,
              device: r.device,
            );
            changes.removed++;
          }
        } else if (existing == null ||
            existing.at.millisecondsSinceEpoch < r.changedAt) {
          _store.unsubscriptions.record(
            accountId: account.id,
            listKey: listKey,
            listName: _text(r, 'listName'),
            kind: UnsubscribeKind.values.byName(_text(r, 'how')),
            now: at,
          );
          changes.added++;
        }
      case RecordKind.folderRule:
        final email = r.deleted ? _keyPart(r.key, 0) : _text(r, 'account');
        final folderName = r.deleted ? _keyPart(r.key, 1) : _text(r, 'folder');
        final field = RuleField.values.byName(
          r.deleted ? _keyPart(r.key, 2) : _text(r, 'field'),
        );
        final value = r.deleted ? _keyPart(r.key, 3) : _text(r, 'value');
        final account = _account(email);
        final folder = account == null
            ? null
            : _store.mailboxes
                  .forAccount(account.id)
                  .where((m) => m.encodedName == folderName)
                  .firstOrNull;
        if (account == null || folder == null) {
          changes.skipped++;
          return;
        }
        final existing = _store.folderRules
            .forMailbox(folder.id)
            .where((x) => x.field == field && x.value == value);
        if (r.deleted) {
          for (final rule in existing.toList()) {
            _store.folderRules.remove(rule.id, at: at, device: r.device);
            changes.removed++;
          }
        } else if (existing.isEmpty) {
          final from = r.data['appliesFrom'];
          _store.folderRules.add(
            accountId: account.id,
            mailboxId: folder.id,
            field: field,
            value: value,
            now: at,
            appliesFrom: from is int
                ? DateTime.fromMillisecondsSinceEpoch(from, isUtc: true)
                : null,
          );
          changes.added++;
        }
    }
  }

  (BlockKind, String) _blockOf(SyncRecord r) => r.deleted
      ? (BlockKind.values.byName(_keyPart(r.key, 0)), _keyPart(r.key, 1))
      : (BlockKind.values.byName(_text(r, 'kind')), _text(r, 'value'));

  Account? _account(String email) => _store.accounts
      .all()
      .where((a) => a.email.toLowerCase() == email.toLowerCase())
      .firstOrNull;

  static String _text(SyncRecord r, String name) {
    final value = r.data[name];
    if (value is! String) throw FormatException('missing $name');
    return value;
  }

  /// Part [index] of a key (`kind:["a","b"]`): what a deletion knows.
  static String _keyPart(String key, int index) {
    final colon = key.indexOf(':');
    final parts = colon < 0 ? null : jsonDecode(key.substring(colon + 1));
    if (parts is! List || index >= parts.length || parts[index] is! String) {
      throw FormatException('malformed key $key');
    }
    return parts[index] as String;
  }
}
