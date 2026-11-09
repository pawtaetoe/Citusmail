// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

double contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

/// The Subscriptions split is drawn in the lagoon ramp from the theme's
/// tokens (not senders' avatar colours), with citrus for what renews
/// this week.
void main() {
  for (final (name, theme) in [
    ('light', CitusmailTheme.light()),
    ('dark', CitusmailTheme.dark()),
  ]) {
    test('$name: one ramp, from strong to soft', () {
      final ramp = CitusPalette.chart(theme.brightness);
      final card = theme.cardTheme.color!;
      expect(ramp, hasLength(5));
      // The biggest part is the strongest against the card...
      final against = [for (final c in ramp) contrast(c, card)];
      expect(against.first, greaterThan(4.5));
      for (var i = 1; i < ramp.length; i++) {
        expect(against[i], lessThan(against[i - 1]));
        // ...and neighbours can be told apart.
        expect(contrast(ramp[i], ramp[i - 1]), greaterThan(1.25));
      }
    });
  }

  group('on the page', () {
    late TestApp app;
    setUp(() async => app = await TestApp.create());
    tearDown(() => app.dispose());

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Color partColour(WidgetTester tester, String name) => tester
        .widget<ColoredBox>(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is Tooltip && (w.message ?? '').startsWith('$name:'),
            ),
            matching: find.byType(ColoredBox),
          ),
        )
        .color;

    testWidgets('the ramp, and citrus for a charge this week', (tester) async {
      app.services.settings.autoRead = false;
      final inbox = app.store.mailboxes.inbox(
        app.store.accounts.all().single.id,
      )!;
      final now = DateTime.now().toUtc();
      MessageSummary receipt(int uid, String company, int daysAgo, String p) =>
          MessageSummary(
            uid: uid,
            receivedAt: now.subtract(Duration(days: daysAgo)),
            subject: 'Your $company receipt',
            from: MailAddress(
              displayName: company,
              localPart: 'info',
              domain: 'mailer.${company.toLowerCase()}.example',
            ),
            snippet: 'Your membership has been renewed. Total S\$$p',
          );
      app.store.messages.upsertSummaries(inbox.id, [
        // Charged 5 days ago: next in about 25 days.
        for (final (i, d) in [5, 35, 65].indexed)
          receipt(300 + i, 'StreamFlix', d, '17.98'),
        // Charged 27 days ago: next in about 3 days.
        for (final (i, d) in [27, 57, 87].indexed)
          receipt(400 + i, 'TunesBox', d, '9.99'),
      ]);

      tester.view.physicalSize = const Size(1400, 900);
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
      await tester.tap(find.text('Found in your mail'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subscriptions'));
      await tester.pump();
      await settle(tester);
      await tester.pumpAndSettle();

      expect(partColour(tester, 'StreamFlix'), CitusPalette.chartLight.first);
      expect(partColour(tester, 'TunesBox'), CitusPalette.citrus);
      expect(find.text('this week'), findsOneWidget);
    });
  });
}
