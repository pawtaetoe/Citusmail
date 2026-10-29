// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/services/secret_store.dart';
import 'package:citusmail/src/ui/device_sync_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_appsync/mail_appsync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  Future<String?> storedCode() =>
      app.services.secrets.read(KeychainSyncCodes.key);

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: 'timed out waiting');
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: DeviceSyncPage(services: app.services)),
    );
    await until(tester, () => find.byType(ListTile).evaluate().isNotEmpty);
  }

  testWidgets('turning on makes a code and keeps it in the keychain only', (
    tester,
  ) async {
    await show(tester);
    expect(find.textContaining('only your devices'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    await until(
      tester,
      () => find.text('Your sync code').evaluate().isNotEmpty,
    );

    final stored = (await tester.runAsync(storedCode))!;
    expect(SyncCode.parse(stored), isNotNull);
    expect(find.text(stored), findsOneWidget);
    expect(find.text('Sync is on'), findsOneWidget);
    expect(find.text('Waiting for the first exchange.'), findsOneWidget);
    // Never in the store's settings.
    expect(
      app.store.database
          .select('SELECT value FROM settings')
          .map((r) => r['value']),
      isNot(contains(stored)),
    );
  });

  testWidgets('joining checks the code before using it', (tester) async {
    await show(tester);
    await tester.tap(find.text('I have a sync code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not-a-code');
    await tester.tap(find.text('Join'));
    await until(
      tester,
      () => find.textContaining('isn\'t a sync code').evaluate().isNotEmpty,
    );
    expect(await tester.runAsync(storedCode), isNull);

    final code = SyncCode.generate();
    // Typed carelessly: lower case, spaces instead of dashes.
    await tester.enterText(
      find.byType(TextField),
      code.toString().toLowerCase().replaceAll('-', ' '),
    );
    await tester.tap(find.text('Join'));
    await until(tester, () => find.text('Sync is on').evaluate().isNotEmpty);
    expect(await tester.runAsync(storedCode), code.toString());
  });

  testWidgets('with the app lock on, showing the code asks for the PIN', (
    tester,
  ) async {
    await tester.runAsync(() => app.services.lock.setPin('482910'));
    await tester.runAsync(() => app.services.deviceSync.start());
    await show(tester);
    await tester.tap(find.text('Show the sync code'));
    await tester.pumpAndSettle();
    expect(find.text('Current PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '482910');
    await tester.tap(find.text('Continue'));
    await until(
      tester,
      () => find.text('Your sync code').evaluate().isNotEmpty,
    );
  });

  testWidgets('turning off works offline and removes the code', (tester) async {
    await tester.runAsync(() => app.services.deviceSync.start());
    await show(tester);
    await tester.tap(find.text('Turn off on this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off'));
    await until(tester, () => find.text('Turn on').evaluate().isNotEmpty);
    expect(await tester.runAsync(storedCode), isNull);
    expect(find.textContaining('encrypted copy stays'), findsOneWidget);
  });
}
