// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';

import '../database/mail_database.dart';
import '../model/blocked_sender.dart';
import '../model/folder_rule.dart';

/// Names for app data that are the same on every device, so the user's
/// devices can tell they mean the same thing (local ids differ).
abstract final class AppDataKeys {
  static String block(BlockKind kind, String value) =>
      'block:${jsonEncode([kind.name, value])}';

  static String unsubscribe(String accountEmail, String listKey) =>
      'unsub:${jsonEncode([accountEmail.toLowerCase(), listKey])}';

  static String imageSender(String address) =>
      'images:${jsonEncode([address.toLowerCase()])}';

  static String folderRule(
    String accountEmail,
    String folder,
    RuleField field,
    String value,
  ) =>
      'rule:${jsonEncode([accountEmail.toLowerCase(), folder, field.name, value])}';
}

/// A removal of app data, remembered so other devices learn about it.
final class Tombstone {
  const Tombstone({
    required this.key,
    required this.kind,
    required this.deletedAt,
    required this.device,
  });

  final String key;

  /// `block`, `unsubscribe`, `imageSender` or `folderRule`.
  final String kind;
  final DateTime deletedAt;
  final String device;
}

/// What app data sync keeps in the store: this device's id, removals
/// (tombstones), and the last merged state of all devices.
final class AppDataSyncRepository {
  AppDataSyncRepository(this._db);

  final MailDatabase _db;

  static const _deviceKey = 'sync.device';

  /// This device's random id (made on first use; not secret).
  String get deviceId {
    String? read() {
      final rows = _db.select('SELECT value FROM settings WHERE key = ?', [
        _deviceKey,
      ]);
      return rows.isEmpty ? null : rows.first.columnAt(0) as String;
    }

    final existing = read();
    if (existing != null) return existing;
    final random = Random.secure();
    final id = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    // Another connection may have made one meanwhile: keep the first.
    _db.execute('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)', [
      _deviceKey,
      id,
    ]);
    return read()!;
  }

  /// Remembers that [key] was removed (a later removal replaces an
  /// earlier one; an earlier one never replaces a later one).
  void recordRemoval(String key, String kind, {DateTime? at, String? device}) =>
      _db.execute(
        'INSERT INTO sync_tombstones (key, kind, deleted_at, device) VALUES (?, ?, ?, ?) '
        'ON CONFLICT (key) DO UPDATE SET kind = excluded.kind, '
        'deleted_at = excluded.deleted_at, device = excluded.device '
        'WHERE excluded.deleted_at > sync_tombstones.deleted_at',
        [
          key,
          kind,
          (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
          device ?? deviceId,
        ],
      );

  List<Tombstone> tombstones() => [
    for (final row in _db.select(
      'SELECT key, kind, deleted_at, device FROM sync_tombstones',
    ))
      Tombstone(
        key: row['key'] as String,
        kind: row['kind'] as String,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(
          row['deleted_at'] as int,
          isUtc: true,
        ),
        device: row['device'] as String,
      ),
  ];

  /// The last merged state: key -> record as JSON text.
  Map<String, String> mergedState() => {
    for (final row in _db.select('SELECT key, record FROM sync_state'))
      row['key'] as String: row['record'] as String,
  };

  void replaceMergedState(Map<String, String> records) => _db.transaction(() {
    _db.execute('DELETE FROM sync_state');
    _db.executeMany('INSERT INTO sync_state (key, record) VALUES (?, ?)', [
      for (final MapEntry(:key, :value) in records.entries) [key, value],
    ]);
  });

  /// Forgets the merged state and removals (sync was turned off). The
  /// device id stays.
  void reset() => _db.transaction(() {
    _db.execute('DELETE FROM sync_state');
    _db.execute('DELETE FROM sync_tombstones');
  });
}
