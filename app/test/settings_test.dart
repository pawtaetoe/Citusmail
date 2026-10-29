// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('notifications can be turned off; it is remembered', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    expect(
      app.services.settings.notifications,
      isTrue,
      reason: 'on by default',
    );
    expect(find.text('Instant mail'), findsNothing, reason: 'Android only');
    await tester.tap(find.text('New mail notifications'));
    await tester.pump();
    expect(app.services.settings.notifications, isFalse);
  });

  testWidgets('Android: instant mail asks the system to start the service', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('citusmail/background'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: true)),
    );
    await tester.tap(find.text('Instant mail'));
    await tester.pump();
    expect(app.services.settings.instantMail, isTrue);
  });

  testWidgets('rules on the mail server: off by default; status per account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    expect(app.services.settings.serverRules, isFalse);
    expect(find.text('alice@citusmail.test'), findsNothing);
    await tester.tap(find.text('Rules on the mail server'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(app.services.settings.serverRules, isTrue);
    expect(find.text('alice@citusmail.test'), findsOneWidget);
  });

  test('server rules status in words', () {
    final at = DateTime.utc(2026);
    expect(serverRulesText(null), contains('next check'));
    expect(
      serverRulesText(ServerRulesStatus(ServerRulesState.active, at)),
      'Running on the server.',
    );
    expect(
      serverRulesText(
        ServerRulesStatus(
          ServerRulesState.otherScriptActive,
          at,
          detail: 'roundcube',
        ),
      ),
      contains('"roundcube"'),
    );
    expect(
      serverRulesText(ServerRulesStatus(ServerRulesState.notSupported, at)),
      contains('doesn\'t support'),
    );
    expect(
      serverRulesText(
        ServerRulesStatus(ServerRulesState.failed, at, detail: 'quota'),
      ),
      contains('quota'),
    );
  });
}
