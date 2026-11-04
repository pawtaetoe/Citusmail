// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/return_mail.dart';
import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Lets isolates (text and markup extraction) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> openDeliveries(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Deliveries'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();
  }

  /// The shops listed under "Can still be returned", in order.
  List<String> returnShops(WidgetTester tester) => [
    for (final card in tester.widgetList<Card>(find.byType(Card)))
      if (card.key case ValueKey<String>(:final value)
          when value.startsWith('return-'))
        value,
  ];

  testWidgets('can still be returned: soonest first, with how', (tester) async {
    seedReturns(app.store, now: DateTime.now().toUtc());
    await openDeliveries(tester);

    expect(find.text('Can still be returned'), findsOneWidget);
    expect(find.textContaining('3 can still be returned'), findsOneWidget);
    expect(returnShops(tester), [
      'return-o:uniqlo.com:SG-ONL-5520193',
      'return-o:apple.com:W1234567890',
      'return-t:NVSGAMZ0099887766',
    ]);
    // Items from the markup, the last day and what it was counted from.
    expect(find.text('Ultra Light Down Jacket and 1 more'), findsOneWidget);
    expect(find.textContaining('· 2 days left'), findsOneWidget);
    expect(find.text('Last day given by the shop'), findsOneWidget);
    expect(find.textContaining('· 11 days left'), findsOneWidget);
    expect(
      find.textContaining('14 days from delivery; counted from the order'),
      findsOneWidget,
    );
    expect(find.textContaining('· 28 days left'), findsOneWidget);
    expect(find.textContaining('30 days from delivery ('), findsOneWidget);
    // Final sale and refunded orders are not listed.
    expect(find.text('Fashion Co'), findsNothing);
    expect(find.text('Shopee'), findsNothing);

    // The delivery's page shows its return deadline.
    await tester.tap(
      find.byKey(const ValueKey('delivery-t:NVSGAMZ0099887766')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Returns'), findsOneWidget);
    expect(
      find.textContaining('· 28 days left\n30 days from delivery'),
      findsOneWidget,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    // A return's email opens right here.
    await tester.tap(find.text('UNIQLO'));
    await settle(tester);
    expect(find.text('Order'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Can still be returned'), findsOneWidget);
  });

  testWidgets('"Returned" and "Keeping it", with Undo, remembered', (
    tester,
  ) async {
    seedReturns(app.store, now: DateTime.now().toUtc());
    await openDeliveries(tester);

    Finder inCard(String key, String text) => find.descendant(
      of: find.byKey(ValueKey('return-$key')),
      matching: find.text(text),
    );

    await tester.tap(inCard('o:uniqlo.com:SG-ONL-5520193', 'Returned'));
    await settle(tester);
    expect(find.text('Marked as returned'), findsOneWidget);
    expect(returnShops(tester), hasLength(2));
    expect(find.textContaining('2 can still be returned'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(returnShops(tester), hasLength(3));

    await tester.tap(inCard('o:apple.com:W1234567890', 'Keeping it'));
    await settle(tester);
    expect(
      find.text('Keeping it: Apple Store won\'t be listed for returns'),
      findsOneWidget,
    );
    expect(returnShops(tester), [
      'return-o:uniqlo.com:SG-ONL-5520193',
      'return-t:NVSGAMZ0099887766',
    ]);
    expect(app.store.settings.read('returns.kept'), 'o:apple.com:W1234567890');

    // Listed again from below.
    await tester.tap(find.text('Show 1 returned or kept'));
    await tester.pumpAndSettle();
    expect(find.text('Keeping it · AirPods Pro 2'), findsOneWidget);
    await tester.tap(find.text('List again'));
    await settle(tester);
    expect(returnShops(tester), hasLength(3));
    expect(app.store.settings.read('returns.kept'), '');
  });

  testWidgets('no return windows: no section', (tester) async {
    await openDeliveries(tester);
    expect(find.text('Can still be returned'), findsNothing);
    expect(find.text('No deliveries found'), findsOneWidget);
  });
}
