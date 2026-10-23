// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import 'app_data_sync_repository.dart';

/// A sender whose images load without asking (when the user's server
/// verified the message really comes from them).
final class ImageSender {
  const ImageSender({
    required this.id,
    required this.address,
    required this.since,
  });

  final int id;

  /// Lower case.
  final String address;
  final DateTime since;
}

/// Senders the user trusts to show images.
final class ImageSenderRepository {
  ImageSenderRepository(this._db);

  final MailDatabase _db;

  static const _columns = 'id, address, since';

  /// Trusts [address]; trusting again keeps the original date.
  ImageSender allow(String address, {DateTime? now}) => _db.transaction(() {
    final normalized = address.trim().toLowerCase();
    if (!RegExp(r'^[^\s@<>()]+@[a-z0-9-]+(\.[a-z0-9-]+)+$')
            .hasMatch(normalized) ||
        normalized.length > 320) {
      throw ArgumentError.value(address, 'address', 'not an address');
    }
    _db.execute(
      'INSERT INTO image_senders (address, since) VALUES (?, ?) '
      'ON CONFLICT (address) DO NOTHING',
      [normalized, (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch],
    );
    return _fromRow(
      _db.select('SELECT $_columns FROM image_senders WHERE address = ?', [
        normalized,
      ]).first,
    );
  });

  /// Removes a sender, remembering the removal for the user's other
  /// devices.
  void remove(int id, {DateTime? at, String? device}) => _db.transaction(() {
    final rows = _db.select('SELECT address FROM image_senders WHERE id = ?', [
      id,
    ]);
    if (rows.isEmpty) return;
    _db.execute('DELETE FROM image_senders WHERE id = ?', [id]);
    AppDataSyncRepository(_db).recordRemoval(
      AppDataKeys.imageSender(rows.first.columnAt(0) as String),
      'imageSender',
      at: at,
      device: device,
    );
  });

  bool isAllowed(String? address) =>
      address != null &&
      _db.select('SELECT 1 FROM image_senders WHERE address = ?', [
        address.toLowerCase(),
      ]).isNotEmpty;

  /// Every trusted sender, newest first.
  List<ImageSender> all() => _db
      .select(
        'SELECT $_columns FROM image_senders ORDER BY since DESC, id DESC',
      )
      .map(_fromRow)
      .toList(growable: false);

  static ImageSender _fromRow(Row row) => ImageSender(
    id: row['id'] as int,
    address: row['address'] as String,
    since: DateTime.fromMillisecondsSinceEpoch(
      row['since'] as int,
      isUtc: true,
    ),
  );
}
