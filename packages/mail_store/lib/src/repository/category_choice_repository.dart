// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/category_choice.dart';
import '../model/message.dart';
import 'category_refresh.dart';

/// The user's category choices per sender and per mailing list. Saving or
/// removing one updates every stored message it covers, atomically.
final class CategoryChoiceRepository {
  CategoryChoiceRepository(this._db);

  final MailDatabase _db;

  /// Saves (or replaces) [choice] and re-sorts the messages it covers.
  void save(CategoryChoice choice) => _db.transaction(() {
    _db.execute(
      'INSERT INTO category_choices (scope, key, category, updated_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (scope, key) DO UPDATE SET category = excluded.category, updated_at = excluded.updated_at',
      [
        choice.scope.name,
        choice.key,
        choice.category.name,
        choice.updatedAt.millisecondsSinceEpoch,
      ],
    );
    _refresh(choice.scope, choice.key);
  });

  /// Removes the choice for [scope] and [key], so rules decide again.
  /// Returns whether there was one.
  bool remove(ChoiceScope scope, String key) => _db.transaction(() {
    final normalized = CategoryChoice.normalizeKey(key);
    _db.execute('DELETE FROM category_choices WHERE scope = ? AND key = ?', [
      scope.name,
      normalized,
    ]);
    final removed = _db.updatedRows > 0;
    if (removed) _refresh(scope, normalized);
    return removed;
  });

  CategoryChoice? find(ChoiceScope scope, String key) {
    final rows = _db.select(
      'SELECT scope, key, category, updated_at FROM category_choices WHERE scope = ? AND key = ?',
      [scope.name, CategoryChoice.normalizeKey(key)],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every choice, newest first (for a settings screen).
  List<CategoryChoice> all() => _db
      .select(
        'SELECT scope, key, category, updated_at FROM category_choices ORDER BY updated_at DESC, key',
      )
      .map(_fromRow)
      .toList(growable: false);

  void _refresh(ChoiceScope scope, String key) => switch (scope) {
    ChoiceScope.sender => CategoryRefresh.bySender(_db, key),
    ChoiceScope.list => CategoryRefresh.byList(_db, key),
  };

  static CategoryChoice _fromRow(Row row) => CategoryChoice(
    scope: ChoiceScope.values.byName(row['scope'] as String),
    key: row['key'] as String,
    category: MessageCategory.values.byName(row['category'] as String),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      row['updated_at'] as int,
      isUtc: true,
    ),
  );
}
