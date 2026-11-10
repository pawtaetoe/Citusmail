// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/app.dart';
import 'package:citusmail/src/services/app_services.dart';
import 'package:citusmail/src/setup/setup_controller.dart';
import 'package:citusmail/src/setup/setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async {
    app = await TestApp.create();
    // A first run: no account yet.
    for (final a in app.services.store.accounts.all()) {
      app.services.store.accounts.remove(a.id);
    }
  });
  tearDown(() => app.dispose());

  Future<SetupController> showManualSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CitusmailApp(startup: () async => StartupReady(app.services)),
    );
    await tester.pump();
    await tester.pump();
    final controller =
        tester.widget<SetupPage>(find.byType(SetupPage)).controller
          ..editSettings();
    await tester.pumpAndSettle();
    expect(controller.state, isA<EditingSettings>());
    return controller;
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('Android Back on the server settings asks before leaving them', (
    tester,
  ) async {
    final controller = await showManualSettings(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server').first,
      'mail.example.org',
    );

    await systemBack(tester);
    expect(find.text('Leave the server settings?'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(controller.state, isA<EditingSettings>());
    expect(find.text('mail.example.org'), findsOneWidget);

    await systemBack(tester);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(controller.state, isA<EnteringCredentials>());
    // Still in the app, on the first step.
    expect(find.byType(SetupPage), findsOneWidget);
  });

  testWidgets('the server settings fit beside the first-run welcome', (
    tester,
  ) async {
    // Fails on a layout overflow if the Security field doesn't fit.
    await showManualSettings(tester);
    expect(find.text('Server settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
