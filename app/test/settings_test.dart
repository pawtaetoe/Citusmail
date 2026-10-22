// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/ui/settings_page.dart';

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
      const MethodChannel('fmail/background'),
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
}
