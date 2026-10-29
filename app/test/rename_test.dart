// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:citusmail/src/services/app_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('citusmail_rename'));
  tearDown(() => dir.deleteSync(recursive: true));

  String at(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('a database from before the rename moves to the new name', () {
    File(at('fmail.db')).writeAsStringSync('db');
    File(at('fmail.db-wal')).writeAsStringSync('wal');
    final path = AppStartup.databasePath(dir);
    expect(path, at('citusmail.db'));
    expect(File(at('citusmail.db')).readAsStringSync(), 'db');
    expect(File(at('citusmail.db-wal')).readAsStringSync(), 'wal');
    expect(File(at('fmail.db')).existsSync(), isFalse);
  });

  test('an interrupted move is finished on the next start', () {
    // The WAL moved, then the app stopped before the main file did.
    File(at('fmail.db')).writeAsStringSync('db');
    File(at('citusmail.db-wal')).writeAsStringSync('wal');
    AppStartup.databasePath(dir);
    expect(File(at('citusmail.db')).readAsStringSync(), 'db');
    expect(File(at('citusmail.db-wal')).readAsStringSync(), 'wal');
  });

  test('the new database is never replaced by an old one', () {
    File(at('citusmail.db')).writeAsStringSync('new');
    File(at('fmail.db')).writeAsStringSync('old');
    AppStartup.databasePath(dir);
    expect(File(at('citusmail.db')).readAsStringSync(), 'new');
    expect(File(at('fmail.db')).existsSync(), isTrue);
  });
}
