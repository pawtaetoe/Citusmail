// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/app.dart';
import 'package:fmail/src/security/lock_screen.dart';
import 'package:fmail/src/services/app_services.dart';
import 'package:fmail/src/ui/settings_page.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// PIN hashing runs in another isolate: real time must pass.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: 'timed out waiting');
  }

  Future<void> showApp(
    WidgetTester tester, {
    Future<StartupResult> Function()? startup,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      FmailApp(startup: startup ?? () async => StartupReady(app.services)),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder lockedTitle() => find.text('$appName is locked');

  /// Unmounts the app (its services are closed by tearDown).
  Future<void> closeApp(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  Future<void> enterPin(WidgetTester tester, String pin) async {
    await tester.enterText(find.widgetWithText(TextField, 'PIN'), pin);
    await tester.tap(find.text('Unlock'));
    await tester.pump();
  }

  testWidgets('the mail stays hidden until the right PIN', (tester) async {
    await tester.runAsync(() => app.services.lock.setPin('482910'));
    await tester.runAsync(app.services.lock.start);
    await showApp(tester);

    expect(lockedTitle(), findsOneWidget);
    expect(find.text('Hello there'), findsNothing);

    await enterPin(tester, '000000');
    await until(
      tester,
      () => find.text('Wrong PIN. Try again.').evaluate().isNotEmpty,
    );
    expect(find.text('Hello there'), findsNothing);

    await enterPin(tester, '482910');
    await until(tester, () => lockedTitle().evaluate().isEmpty);
    expect(find.text('Hello there'), findsOneWidget);

    // "Lock now" covers everything again, pages included.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('App lock'), findsOneWidget);
    app.services.lock.lockNow();
    await tester.pump();
    expect(lockedTitle(), findsOneWidget);
    expect(find.text('App lock'), findsNothing);
    await closeApp(tester);
  });

  testWidgets('too many wrong PINs: a visible wait', (tester) async {
    await tester.runAsync(() => app.services.lock.setPin('482910'));
    await tester.runAsync(app.services.lock.start);
    await showApp(tester);
    for (var i = 0; i < 5; i++) {
      await enterPin(tester, '000000');
      await until(
        tester,
        () =>
            find.widgetWithText(TextField, 'PIN').evaluate().isNotEmpty &&
            tester
                .widget<TextField>(find.widgetWithText(TextField, 'PIN'))
                .controller!
                .text
                .isEmpty,
      );
    }
    await until(
      tester,
      () => find.textContaining('Too many wrong PINs').evaluate().isNotEmpty,
    );
    expect(find.textContaining('Try again in 0:'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Unlock'))
          .onPressed,
      isNull,
    );
    await closeApp(tester);
  });

  testWidgets('Forgot PIN: a clear warning, then everything stays covered', (
    tester,
  ) async {
    // The real wipe is tested in app_lock_test; here, what the user sees.
    final lock = app.services.lock;
    await tester.runAsync(() => lock.setPin('482910'));
    await tester.runAsync(lock.start);
    final host = LockHost();
    final resetting = Completer<void>();
    var resets = 0;
    host.attach(
      lock,
      reset: () {
        resets++;
        return resetting.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => LockGate(host: host, child: child!),
        home: const Scaffold(body: Text('Secret mail')),
      ),
    );
    expect(find.text('Secret mail'), findsNothing);

    await tester.tap(find.text('Forgot PIN?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('removes your accounts'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resets, 0);

    await tester.tap(find.text('Forgot PIN?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(resets, 1);
    expect(host.resetting, isTrue);
    expect(lockedTitle(), findsNothing);
    expect(find.text('Secret mail'), findsNothing, reason: 'still covered');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    resetting.complete();
    host.clear(); // what a fresh start does when it finds no accounts
    await tester.pump();
    expect(find.text('Secret mail'), findsOneWidget);
  });

  testWidgets('Settings: turn on with a PIN, choose when, turn off with it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    await tester.pump();
    await tester.tap(find.text('App lock'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'New PIN'), '12');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Use 4 to 16 digits.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'New PIN'), '482910');
    await tester.enterText(
      find.widgetWithText(TextField, 'Repeat the PIN'),
      '482911',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('The PINs don\'t match.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Repeat the PIN'),
      '482910',
    );
    await tester.tap(find.text('Save'));
    await until(tester, () => app.services.lock.enabled);
    await tester.pumpAndSettle();

    expect(find.text('After 1 minute'), findsOneWidget);
    expect(find.text('Change PIN'), findsOneWidget);
    await tester.tap(find.text('After 1 minute'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Immediately').last);
    await tester.pumpAndSettle();
    expect(app.services.lock.timeout.name, 'immediately');

    await tester.tap(find.text('App lock'));
    await tester.pumpAndSettle();
    expect(find.text('Turn off the app lock?'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Current PIN'),
      '000000',
    );
    await tester.tap(find.text('Continue'));
    await until(tester, () => find.text('Wrong PIN.').evaluate().isNotEmpty);
    await tester.enterText(
      find.widgetWithText(TextField, 'Current PIN'),
      '482910',
    );
    await tester.tap(find.text('Continue'));
    await until(tester, () => !app.services.lock.enabled);
    await tester.pumpAndSettle();
    expect(find.text('Change PIN'), findsNothing);
  });
}
