// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/delivery_mail.dart';
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
    tester.view.physicalSize = const Size(1400, 1000);
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
    // In the sidebar's "Found in your mail" group, folded at first.
    await tester.tap(find.text('Found in your mail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deliveries'));
    await tester.pump();
    await settle(tester);
    await tester.pumpAndSettle();
  }

  testWidgets('shipped orders: on the way, delivered, older', (tester) async {
    // Reading automatically off: the page offers it, as a card.
    app.services.settings.autoRead = false;
    seedDeliveries(app.store, now: DateTime.now().toUtc());
    await openDeliveries(tester);

    expect(find.text('3 on the way'), findsOneWidget);
    expect(
      find.text('1 out for delivery · 1 delivered in the last 30 days'),
      findsOneWidget,
    );
    // Soonest first: out for delivery, then by expected date.
    final shops = [
      for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
        ((t.title! as Text).data),
    ];
    expect(shops.take(4), ['Shopee', 'Amazon.sg', 'UPS', 'SingPost']);
    expect(
      find.text('Kindle Paperwhite (16 GB) and 1 more'),
      findsOneWidget,
      reason: 'items from the markup',
    );
    expect(
      find.textContaining('Out for delivery · Shopee Express'),
      findsOneWidget,
    );
    expect(find.textContaining('Expected '), findsNWidgets(2));
    expect(find.textContaining('Delivered '), findsOneWidget);
    // Not deliveries.
    expect(find.text('Fashion Co'), findsNothing);
    expect(find.text('FedEx Billing'), findsNothing);
    // Older ones are folded away.
    expect(find.text('Book Depot'), findsNothing);
    await tester.tap(find.text('Show 2 older deliveries'));
    await tester.pumpAndSettle();
    expect(find.text('Book Depot'), findsOneWidget);
    expect(find.text('Probably delivered · Ninja Van'), findsOneWidget);
    // Shipping emails not on the device (the Shopee ones have no date
    // yet; one is not understood at all) are offered for reading.
    expect(find.textContaining('found in 3 shipping emails'), findsOneWidget);
  });

  testWidgets('a delivery: tracking, its emails, marking and hiding', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    seedDeliveries(app.store, now: DateTime.now().toUtc());
    await openDeliveries(tester);

    await tester.tap(find.text('Amazon.sg'));
    await tester.pumpAndSettle();
    expect(
      find.text('Kindle Paperwhite (16 GB)\nUSB-C charging cable'),
      findsOneWidget,
    );
    expect(find.text('NVSGAMZ0012345678'), findsOneWidget);
    expect(find.text('171-5551234-7654321'), findsOneWidget);
    expect(find.text('Ninja Van'), findsOneWidget);

    // Copy with a tap.
    await tester.tap(find.byTooltip('Copy tracking number'));
    await tester.pump();
    expect(copied, ['NVSGAMZ0012345678']);
    expect(find.text('Tracking number copied'), findsOneWidget);

    // The carrier's page opens only after asking.
    await tester.tap(find.text('Track on Ninja Van'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link?'), findsOneWidget);
    expect(
      find.textContaining('ninjavan.co/en-sg/tracking?id=NVSGAMZ'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Its email opens right here; Back returns to the delivery.
    await tester.tap(find.text('Shipped'));
    await settle(tester);
    expect(find.text('Email'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Track on Ninja Van'), findsOneWidget);

    // "Mark as delivered": back to the list, with Undo.
    await tester.tap(find.text('Mark as delivered'));
    await settle(tester);
    expect(find.text('Marked as delivered'), findsWidgets);
    expect(find.text('2 on the way'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('3 on the way'), findsOneWidget);

    // "Not a delivery": hidden, with Undo, and listed again from below.
    await tester.tap(find.text('UPS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not a delivery'));
    await settle(tester);
    expect(find.text('UPS won\'t be listed as a delivery'), findsOneWidget);
    expect(find.text('2 on the way'), findsOneWidget);
    await tester.tap(find.text('Show 1 marked "not a delivery"'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('List again'));
    await settle(tester);
    expect(find.text('3 on the way'), findsOneWidget);
  });

  testWidgets('a lookalike tracking page from the email\'s data is flagged', (
    tester,
  ) async {
    // The shop's markup names an unknown carrier and a tracking page
    // whose address is "pаypal.com" with a Cyrillic а, as punycode.
    final store = app.store;
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    final now = DateTime.now().toUtc();
    final summary = MessageSummary(
      uid: 900,
      receivedAt: now.subtract(const Duration(hours: 3)),
      subject: 'Your order has shipped',
      from: const MailAddress(
        localPart: 'orders',
        domain: 'gadgetshop.example',
        displayName: 'Gadget Shop',
      ),
      snippet: 'Your package is on its way.',
      size: 2000,
      category: MessageCategory.notifications,
      flags: MessageFlags.fromImap([r'\Seen']),
    );
    store.messages.upsertSummaries(inbox.id, [summary]);
    final stored = store.messages.byUid(inbox.id, 900)!;
    const raw =
        'From: Gadget Shop <orders@gadgetshop.example>\r\n'
        'To: alice@citusmail.test\r\n'
        'Subject: Your order has shipped\r\n'
        'Content-Type: text/html; charset=utf-8\r\n'
        '\r\n'
        '<html><head><script type="application/ld+json">\r\n'
        '{"@context": "http://schema.org", "@type": "ParcelDelivery",\r\n'
        ' "carrier": {"@type": "Organization", "name": "Speedy Parcel"},\r\n'
        ' "trackingNumber": "SP0012345678",\r\n'
        ' "trackingUrl": "https://xn--pypal-4ve.com/track?id=SP0012345678",\r\n'
        ' "partOfOrder": {"@type": "Order", "orderNumber": "GS-1001",\r\n'
        '   "merchant": {"@type": "Organization", "name": "Gadget Shop"},\r\n'
        '   "orderStatus": "http://schema.org/OrderInTransit"}}\r\n'
        '</script></head>\r\n'
        '<body><p>Your package is on its way.</p></body></html>\r\n';
    store.messages.saveBody(
      stored.id,
      utf8.encode(raw),
      searchableText: 'Your package is on its way.',
    );
    await openDeliveries(tester);

    await tester.tap(find.text('Gadget Shop'));
    await tester.pumpAndSettle();
    expect(find.text('Track on Speedy Parcel'), findsOneWidget);
    await tester.tap(find.text('Track on Speedy Parcel'));
    await tester.pumpAndSettle();

    // The same red warning the reader would show for this link.
    expect(find.text('Open this link anyway?'), findsOneWidget);
    expect(
      find.textContaining('letters from another alphabet'),
      findsOneWidget,
    );
    expect(find.text('Don\'t open'), findsOneWidget);
    await tester.tap(find.text('Don\'t open'));
    await tester.pumpAndSettle();
    expect(find.text('Open this link anyway?'), findsNothing);
  });
}
