// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'cipher.dart';
import 'sync_code.dart';

/// The kinds of app data that sync.
enum RecordKind { block, unsubscribe, imageSender, folderRule }

/// One piece of app data, or the fact that it was removed.
///
/// [key] names the thing (`block:domain:spam.example`) the same way on
/// every device; [data] is what a device needs to recreate it. Deletions
/// are kept as records ("tombstones") so a device that was offline learns
/// about them instead of bringing the data back.
final class SyncRecord {
  SyncRecord({
    required this.key,
    required this.kind,
    required this.changedAt,
    required this.device,
    Map<String, Object?> data = const {},
    this.deleted = false,
  }) : data = Map.unmodifiable(data) {
    if (key.isEmpty || key.length > maxKeyLength) {
      throw ArgumentError.value(key, 'key', 'empty or too long');
    }
  }

  static const maxKeyLength = 600;

  final String key;
  final RecordKind kind;

  /// Milliseconds since the epoch (UTC) of the change.
  final int changedAt;

  /// The device that made the change.
  final String device;
  final Map<String, Object?> data;
  final bool deleted;

  /// Which of two versions of the same record wins: the later change; on
  /// a tie a deletion (the safer outcome); then the device id, so every
  /// device picks the same one.
  static SyncRecord newer(SyncRecord a, SyncRecord b) {
    if (a.changedAt != b.changedAt) return a.changedAt > b.changedAt ? a : b;
    if (a.deleted != b.deleted) return a.deleted ? a : b;
    return a.device.compareTo(b.device) >= 0 ? a : b;
  }

  Map<String, Object?> toJson() => {
    'k': key,
    't': kind.name,
    'at': changedAt,
    'dev': device,
    if (deleted) 'del': true,
    if (!deleted && data.isNotEmpty) 'd': data,
  };

  static SyncRecord fromJson(Object? json) {
    if (json is! Map) throw const FormatException('record is not an object');
    final key = json['k'], kind = json['t'], at = json['at'], dev = json['dev'];
    final data = json['d'] ?? const <String, Object?>{};
    if (key is! String ||
        kind is! String ||
        at is! int ||
        dev is! String ||
        data is! Map) {
      throw const FormatException('malformed record');
    }
    final recordKind = RecordKind.values
        .where((k) => k.name == kind)
        .firstOrNull;
    if (recordKind == null) throw FormatException('unknown kind $kind');
    return SyncRecord(
      key: key,
      kind: recordKind,
      changedAt: at,
      device: dev,
      data: data.cast<String, Object?>(),
      deleted: json['del'] == true,
    );
  }
}

/// Everything one device knows, at one moment.
final class SyncSnapshot {
  SyncSnapshot({
    required this.device,
    required this.createdAt,
    required List<SyncRecord> records,
  }) : records = List.unmodifiable(records);

  static const maxRecords = 50000;
  static const maxBytes = 8 * 1024 * 1024;

  final String device;
  final int createdAt;
  final List<SyncRecord> records;

  /// The merged view of [snapshots]: per key, the record that wins.
  static Map<String, SyncRecord> merge(Iterable<SyncSnapshot> snapshots) {
    final out = <String, SyncRecord>{};
    for (final snapshot in snapshots) {
      for (final record in snapshot.records) {
        final current = out[record.key];
        out[record.key] = current == null
            ? record
            : SyncRecord.newer(current, record);
      }
    }
    return out;
  }
}

/// Seals snapshots for storage on the mail server, and opens them.
///
/// Layout: `CMSYNC1` | 12-byte random nonce | ChaCha20-Poly1305 of the
/// snapshot's JSON. The associated data binds it to the sync id and the
/// device id written next to it, so a stored snapshot can't be passed off
/// as another device's or another code's.
final class SnapshotSealer {
  SnapshotSealer(this.keys, {Random? random})
    : _random = random ?? Random.secure();

  final SyncKeys keys;
  final Random _random;

  static final _magic = ascii.encode('CMSYNC1');

  Uint8List seal(SyncSnapshot snapshot) {
    if (snapshot.records.length > SyncSnapshot.maxRecords) {
      throw ArgumentError('too many records');
    }
    final json = utf8.encode(
      jsonEncode({
        'v': 1,
        'dev': snapshot.device,
        'at': snapshot.createdAt,
        'r': [for (final r in snapshot.records) r.toJson()],
      }),
    );
    if (json.length > SyncSnapshot.maxBytes) {
      throw ArgumentError('snapshot too large');
    }
    final nonce = Uint8List.fromList([
      for (var i = 0; i < ChaCha20Poly1305.nonceLength; i++)
        _random.nextInt(256),
    ]);
    final sealed = ChaCha20Poly1305.encrypt(
      keys.encryptionKey,
      nonce,
      json,
      aad: _aad(snapshot.device),
    );
    return Uint8List.fromList([..._magic, ...nonce, ...sealed]);
  }

  /// The snapshot of [device] in [bytes]. Throws [AuthenticationFailed]
  /// for data that isn't this code's or was changed, [FormatException] for
  /// anything malformed inside.
  SyncSnapshot open(Uint8List bytes, {required String device}) {
    final header = _magic.length + ChaCha20Poly1305.nonceLength;
    if (bytes.length < header + ChaCha20Poly1305.tagLength ||
        bytes.length > SyncSnapshot.maxBytes + header + 16) {
      throw const FormatException('not a snapshot');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) throw const FormatException('not a snapshot');
    }
    final json = ChaCha20Poly1305.decrypt(
      keys.encryptionKey,
      bytes.sublist(_magic.length, header),
      bytes.sublist(header),
      aad: _aad(device),
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(json));
    } on FormatException {
      throw const FormatException('snapshot is not JSON');
    }
    if (decoded is! Map ||
        decoded['v'] != 1 ||
        decoded['dev'] != device ||
        decoded['at'] is! int ||
        decoded['r'] is! List) {
      throw const FormatException('malformed snapshot');
    }
    final raw = decoded['r'] as List;
    if (raw.length > SyncSnapshot.maxRecords) {
      throw const FormatException('too many records');
    }
    return SyncSnapshot(
      device: device,
      createdAt: decoded['at'] as int,
      records: [for (final r in raw) SyncRecord.fromJson(r)],
    );
  }

  List<int> _aad(String device) => [
    ..._magic,
    ...ascii.encode(keys.syncId),
    0,
    ...utf8.encode(device),
  ];
}
