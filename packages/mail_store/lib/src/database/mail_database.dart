// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'database_key.dart';
import 'file_permissions.dart';
import 'schema.dart';
import 'store_exception.dart';

/// The encrypted SQLite database (SQLite3MultipleCiphers, ChaCha20-Poly1305).
///
/// Opening fails closed: if the SQLite library cannot encrypt, or the file
/// would be written unencrypted, nothing is stored. Calls are synchronous;
/// run heavy work off the UI isolate.
final class MailDatabase {
  MailDatabase._(this._db, this.path);

  final Database _db;

  /// File path, or `:memory:`.
  final String path;

  int _savepointDepth = 0;
  bool _closed = false;

  /// The plain-SQLite file signature; an encrypted file must never start
  /// with it.
  static const _plainHeader = 'SQLite format 3\u0000';

  /// Opens (or creates) the database at [path] with [key] and brings the
  /// schema up to date.
  static MailDatabase open(
    String path,
    DatabaseKey key, {
    List<Migration> migrations = schemaMigrations,
  }) {
    _requireEncryptingSqlite();
    final db = sqlite3.open(path);
    try {
      db.execute("PRAGMA cipher = 'chacha20'");
      // PRAGMA cannot take bound parameters; DatabaseKey.hex is always
      // exactly 64 lower-case hex characters, so this cannot inject SQL.
      db.execute("PRAGMA hexkey = '${key.hex}'");
      _verifyKey(db);
      _configure(db);
      _migrate(db, migrations);
      final database = MailDatabase._(db, path);
      database._verifyFileIsEncrypted();
      FilePermissions.restrict(path);
      return database;
    } on Object {
      db.close();
      rethrow;
    }
  }

  /// Deletes the database and its WAL files. For a corrupted cache or a
  /// lost key; everything except local-only data can be re-downloaded.
  static void destroy(String path) {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Current schema version.
  int get schemaVersion =>
      _db.select('PRAGMA user_version').first.columnAt(0) as int;

  /// Runs [action] atomically. Nested calls use savepoints, so an inner
  /// failure rolls back only the inner part (and rethrows).
  ///
  /// The outermost level takes the write lock up front (BEGIN IMMEDIATE).
  /// The UI and the sync worker each have a connection; a transaction that
  /// read first and wrote later could otherwise fail if the other
  /// connection wrote in between. Waiting for the lock is bounded by
  /// `busy_timeout`.
  T transaction<T>(T Function() action) {
    _checkOpen();
    final outermost = _savepointDepth == 0;
    final name = 'sp${_savepointDepth++}';
    _db.execute(outermost ? 'BEGIN IMMEDIATE' : 'SAVEPOINT $name');
    try {
      final result = action();
      if (result is Future) {
        throw StateError(
          'transactions are synchronous; do not return a Future',
        );
      }
      _db.execute(outermost ? 'COMMIT' : 'RELEASE $name');
      return result;
    } on Object {
      if (outermost) {
        _db.execute('ROLLBACK');
      } else {
        _db.execute('ROLLBACK TO $name');
        _db.execute('RELEASE $name');
      }
      rethrow;
    } finally {
      _savepointDepth--;
    }
  }

  /// Runs a statement with bound parameters. Values are always bound,
  /// never spliced into SQL text.
  void execute(String sql, [List<Object?> parameters = const []]) {
    _checkOpen();
    _db.execute(sql, parameters);
  }

  /// Runs a query with bound parameters.
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    _checkOpen();
    return _db.select(sql, parameters);
  }

  /// Runs [sql] once per parameter list with one prepared statement.
  void executeMany(String sql, Iterable<List<Object?>> rows) {
    _checkOpen();
    final statement = _db.prepare(sql);
    try {
      for (final row in rows) {
        statement.execute(row);
      }
    } finally {
      statement.close();
    }
  }

  int get lastInsertRowId => _db.lastInsertRowId;

  /// Rows changed by the last statement.
  int get updatedRows => _db.updatedRows;

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  // ---------------------------------------------------------------------

  /// The library must be SQLite3MultipleCiphers: a plain SQLite silently
  /// ignores PRAGMA hexkey and would write mail unencrypted. Checked on a
  /// separate in-memory database, because any statement on an encrypted
  /// file fails until the key is set.
  static void _requireEncryptingSqlite() {
    final probe = sqlite3.openInMemory();
    try {
      probe.select('SELECT sqlite3mc_version()');
    } on SqliteException {
      throw const EncryptionUnavailableException(
        'the loaded SQLite library cannot encrypt (SQLite3MultipleCiphers is required)',
      );
    } finally {
      probe.close();
    }
  }

  static void _verifyKey(Database db) {
    try {
      db.select('SELECT count(*) FROM sqlite_master');
    } on SqliteException catch (e) {
      if (e.resultCode == 26) throw const WrongKeyException(); // SQLITE_NOTADB
      rethrow;
    }
    final cipher = db.select('PRAGMA cipher').firstOrNull?.columnAt(0);
    if (cipher != 'chacha20') {
      throw EncryptionUnavailableException('unexpected cipher: $cipher');
    }
  }

  static void _configure(Database db) {
    db
      // Temporary tables and sort spills stay in memory: temp files are
      // not encrypted.
      ..execute('PRAGMA temp_store = MEMORY')
      // Deleted content is overwritten, not just unlinked.
      ..execute('PRAGMA secure_delete = ON')
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('PRAGMA journal_mode = WAL') // the WAL file is encrypted too
      ..execute('PRAGMA synchronous = NORMAL')
      ..execute('PRAGMA busy_timeout = 5000');
  }

  static void _migrate(Database db, List<Migration> migrations) {
    final latest = migrations.isEmpty ? 0 : migrations.last.version;
    final current = db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (current > latest) throw DatabaseTooNewException(current, latest);
    for (final migration in migrations.where((m) => m.version > current)) {
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final statement in migration.statements) {
          db.execute(statement);
        }
        // user_version is an integer we control; safe to write inline.
        db.execute('PRAGMA user_version = ${migration.version}');
        db.execute('COMMIT');
      } on Object catch (e) {
        db.execute('ROLLBACK');
        throw MigrationException(migration.version, e);
      }
    }
  }

  void _verifyFileIsEncrypted() {
    if (path == ':memory:' || path.isEmpty) return;
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < 16) return;
    final raf = file.openSync();
    try {
      final header = String.fromCharCodes(raf.readSync(16));
      if (header == _plainHeader) {
        close();
        throw const EncryptionUnavailableException(
          'the database file is not encrypted',
        );
      }
    } finally {
      raf.closeSync();
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('database is closed');
  }
}
