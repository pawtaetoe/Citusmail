// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/setup/setup_controller.dart';
import 'package:citusmail/src/setup/setup_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_setup/mail_setup.dart';

/// The first thing a new user sees says what the app is, then asks for
/// an account; adding another account later is just the form.
void main() {
  SetupController controller() => SetupController(
    discover: (email, {askMozillaConsent, onStep}) async =>
        const DiscoveryResult(null),
    verify: (s, p) async => const VerificationResult.success(),
    save: (s, p, {displayName}) async => throw UnimplementedError(),
  );

  Future<void> show(
    WidgetTester tester,
    Size size, {
    VoidCallback? onCancel,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SetupPage(
          controller: controller(),
          onDone: (_) {},
          onCancel: onCancel,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('wide: a welcome beside the form, no app bar', (tester) async {
    await show(tester, const Size(1400, 900));
    expect(find.text('Welcome to Citusmail'), findsOneWidget);
    expect(find.text('Your password stays on this device'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Add account'), findsNothing);
    // Beside the form, on the sidebar's spruce.
    final welcome = tester.getRect(find.byKey(const ValueKey('welcome')));
    final email = tester.getRect(
      find.widgetWithText(TextField, 'Email address'),
    );
    expect(welcome.right, lessThan(email.left));
    expect(
      find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == CitusPalette.spruce,
      ),
      findsOneWidget,
    );
    // One mark: the big one in the welcome.
    expect(find.byType(CitusMark), findsOneWidget);
    expect(tester.getSize(find.byType(CitusMark)).width, 96);
  });

  testWidgets('phone: the welcome above the form', (tester) async {
    await show(tester, const Size(390, 844));
    final welcome = tester.getRect(find.byKey(const ValueKey('welcome')));
    final heading = tester.getRect(find.text('Sign in to your email'));
    expect(welcome.bottom, lessThan(heading.top));
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('adding another account: just the form', (tester) async {
    await show(tester, const Size(1400, 900), onCancel: () {});
    expect(find.text('Welcome to Citusmail'), findsNothing);
    expect(find.text('Add account'), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    expect(find.byType(CitusMark), findsOneWidget);
  });
}
