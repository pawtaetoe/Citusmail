// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// One company's several lines as subscriptions of their own (hidden,
// listed again, on the calendar), and a price change on a subscription's
// page; with an invented telco, numbers and amounts.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/calendar/state/calendar_model.dart';
import 'package:citusmail/src/features/found/state/subscriptions_model.dart';
import 'package:citusmail/src/features/found/ui/subscription_detail_page.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// Two lines of one telco, each renewing every month.
  void seedLines(DateTime now) {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    app.store.messages.upsertSummaries(inbox.id, [
      for (final (l, (line, total)) in [
        ('4821', '\$15.00'),
        ('7731', '\$30.00'),
      ].indexed)
        for (final (i, daysAgo) in [5, 35, 65].indexed)
          MessageSummary(
            uid: 700 + 10 * l + i,
            receivedAt: now.subtract(Duration(days: daysAgo)),
            subject: 'Your ExampleTel plan has renewed',
            from: const MailAddress(
              displayName: 'ExampleTel',
              localPart: 'no-reply',
              domain: 'mail.telco.example',
            ),
            snippet:
                'Your plan for mobile number ending $line has renewed. '
                'Total $total',
          ),
    ]);
  }

  Future<void> settle(SubscriptionsModel model) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await model.load();
  }

  test('each line its own subscription, keyed by the company', () async {
    final now = DateTime.now().toUtc();
    seedLines(now);
    final found = await findSubscriptions(
      app.store,
      now,
      monthlyRenewals: true,
    );
    expect(found.all.map((s) => s.company).toSet(), {
      'telco.example#4821',
      'telco.example#7731',
    });
    expect(found.all.map((s) => s.name).toSet(), {
      'ExampleTel ·4821',
      'ExampleTel ·7731',
    });
    // Both on the calendar, each under its own key.
    final items = await findCalendar(app.store, now);
    expect(
      items.map((i) => i.key),
      containsAll([
        'money:renewal:telco.example#4821',
        'money:renewal:telco.example#7731',
      ]),
    );
  });

  test('the company hidden before its lines were told apart', () async {
    final now = DateTime.now().toUtc();
    seedLines(now);
    SubscriptionsModel.hiddenSetting.write(app.store.settings, [
      'telco.example',
    ]);
    final model = SubscriptionsModel(app.services);
    await model.load();
    // Both lines stay hidden, on the page and on the calendar.
    expect(model.subscriptions, isEmpty);
    expect(model.hiddenOnes, hasLength(2));
    final items = await findCalendar(app.store, now);
    expect(
      items.where((i) => i.key.startsWith('money:renewal:telco.example')),
      isEmpty,
    );
    // One listed again: the other stays hidden.
    model.unhide('telco.example#4821');
    await settle(model);
    expect(model.subscriptions.map((s) => s.company), ['telco.example#4821']);
    expect(model.hiddenOnes.map((s) => s.company), ['telco.example#7731']);
    expect(SubscriptionsModel.hiddenSetting.read(app.store.settings), [
      'telco.example#7731',
    ]);
    // Hiding the listed one again hides it alone.
    model.hide('telco.example#4821');
    await settle(model);
    expect(model.subscriptions, isEmpty);
    model.dispose();
  });

  testWidgets('a subscription\'s page shows its price change', (tester) async {
    final on = DateTime.now().toUtc().add(const Duration(days: 20));
    final day = DateTime.utc(on.year, on.month, on.day);
    final s = Subscription(
      company: 'telco.example#4821',
      name: 'ExampleTel ·4821',
      records: [
        SubscriptionRecord(
          SubscriptionEmail(
            messageId: const MessageId(1),
            company: 'telco.example',
            senderName: 'ExampleTel',
            subject: 'Your price is changing',
            text: 'From then your plan will change to \$12.99/month.',
            at: DateTime.now().toUtc(),
          ),
          SubscriptionEvent.notice,
          null,
        ),
      ],
      cadence: Cadence.monthly,
      amount: const Money(1299, r'$'),
      status: SubscriptionStatus.active,
      nextCharge: day,
      priceChange: PriceChange(to: const Money(1299, r'$'), on: day),
    );
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: SubscriptionDetailPage(
          subscription: s,
          controller: MailController(app.services),
          messageById: (_) => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(SubscriptionDetailPage));
    final date = MaterialLocalizations.of(context)
        .formatMediumDate(day.toLocal());
    expect(find.textContaining('Price changes to'), findsOneWidget);
    expect(find.textContaining('on $date'), findsOneWidget);
    expect(find.text('Number ending 4821'), findsOneWidget);
    expect(find.text('telco.example'), findsOneWidget);
  });
}
