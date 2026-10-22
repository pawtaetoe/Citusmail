// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/blocked_sender.dart';

/// The user's blocked senders.
final class BlockRepository {
  BlockRepository(this._db);

  final MailDatabase _db;

  static const _columns = 'id, kind, value, since';

  /// Blocks [value]; blocking again keeps the original date.
  BlockedSender block(
    BlockKind kind,
    String value, {
    DateTime? now,
  }) => _db.transaction(() {
    final normalized = BlockedSender.normalize(kind, value);
    _db.execute(
      'INSERT INTO blocked_senders (kind, value, since) VALUES (?, ?, ?) '
      'ON CONFLICT (kind, value) DO NOTHING',
      [
        kind.name,
        normalized,
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
      ],
    );
    return _fromRow(
      _db.select(
        'SELECT $_columns FROM blocked_senders WHERE kind = ? AND value = ?',
        [kind.name, normalized],
      ).first,
    );
  });

  void unblock(int id) =>
      _db.execute('DELETE FROM blocked_senders WHERE id = ?', [id]);

  /// Every block, newest first.
  List<BlockedSender> all() => _db
      .select(
        'SELECT $_columns FROM blocked_senders ORDER BY since DESC, id DESC',
      )
      .map(_fromRow)
      .toList(growable: false);

  /// The block that applies to mail from [address], if any (an address
  /// block before a domain block).
  BlockedSender? matching(String? address) {
    if (address == null) return null;
    final lower = address.toLowerCase();
    final at = lower.lastIndexOf('@');
    if (at < 0) return null;
    // The domain and each parent domain: a.b.shop.example -> shop.example.
    final labels = lower.substring(at + 1).split('.');
    final domains = [
      for (var i = 0; i < labels.length - 1; i++) labels.sublist(i).join('.'),
    ];
    final rows = _db.select(
      'SELECT $_columns FROM blocked_senders '
      "WHERE (kind = 'address' AND value = ?) "
      "OR (kind = 'domain' AND value IN (${List.filled(domains.length, '?').join(', ')})) "
      "ORDER BY kind = 'domain', id LIMIT 1",
      [lower, ...domains],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  static BlockedSender _fromRow(Row row) => BlockedSender(
    id: row['id'] as int,
    kind: BlockKind.values.byName(row['kind'] as String),
    value: row['value'] as String,
    since: DateTime.fromMillisecondsSinceEpoch(
      row['since'] as int,
      isUtc: true,
    ),
  );
}
