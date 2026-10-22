// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/link_opener.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:fmail/src/ui/settings_page.dart';
import 'package:mail_store/mail_store.dart';

import 'support/fake_web.dart';
import 'support/test_app.dart';

/// A real 1 x 1 PNG.
final _png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _newsletter = '50% off everything this week';

void main() {
  late FakeWeb web;
  late TestApp app;

  setUp(() async {
    web = await FakeWeb.start();
    web.serve('GET /banner.jpg', _png);
    app = await TestApp.create(web: web.client);
  });

  tearDown(() async {
    await app.dispose();
    await web.close();
  });

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: FmailTheme.light(),
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () {},
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  /// Real sockets complete in steps, each needing a real wait and a pump.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 40 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: 'timed out waiting');
  }

  Future<void> open(WidgetTester tester, String subject) async {
    await tester.tap(find.text(subject).first);
    await until(
      tester,
      // Reply appears once the message is parsed and shown.
      () => find.byTooltip('Reply (R)').evaluate().isNotEmpty,
    );
  }

  Finder memoryImages() =>
      find.byWidgetPredicate((w) => w is Image && w.image is ResizeImage);

  testWidgets('images stay hidden until asked; trackers never load', (
    tester,
  ) async {
    app.seedFixture(
      'newsletters/one-click-unsubscribe.eml',
      subject: _newsletter,
      uid: 70,
    );
    await show(tester);
    await open(tester, _newsletter);

    expect(
      find.textContaining(
        'Blocked a tracker that would tell track.shop.example',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('1 image is hidden'), findsOneWidget);
    expect(find.textContaining('[Banner]'), findsOneWidget);
    expect(web.requests, isEmpty);

    await tester.tap(find.text('Load images'));
    await until(tester, () => web.requests.isNotEmpty);
    await until(tester, () => memoryImages().evaluate().isNotEmpty);
    expect(web.requests, ['cdn.shop.example GET /banner.jpg']);
    expect(find.textContaining('1 image is hidden'), findsNothing);
    expect(app.store.imageSenders.all(), isEmpty, reason: 'this message only');
  });

  testWidgets('"Always from this sender" loads them next time by itself', (
    tester,
  ) async {
    app.seedFixture(
      'newsletters/one-click-unsubscribe.eml',
      subject: _newsletter,
      uid: 70,
    );
    await show(tester);
    await open(tester, _newsletter);
    await tester.tap(find.text('Always from this sender'));
    await until(tester, () => memoryImages().evaluate().isNotEmpty);
    expect(app.store.imageSenders.all().single.address, 'news@shop.example');

    await tester.tap(find.byTooltip('Close (Esc)'));
    await tester.pump();
    await open(tester, _newsletter);
    expect(find.text('Load images'), findsNothing);
    await until(tester, () => memoryImages().evaluate().isNotEmpty);
  });

  testWidgets('an unverified sender can\'t be trusted for images', (
    tester,
  ) async {
    app.seedFixture(
      'newsletters/one-click-dkim-fail.eml',
      subject: 'Last chance: 50% off',
      uid: 71,
    );
    app.store.imageSenders.allow('news@shop.example');
    await show(tester);
    await open(tester, 'Last chance: 50% off');
    expect(find.text('Load images'), findsOneWidget, reason: 'not automatic');
    expect(find.text('Always from this sender'), findsNothing);
  });

  testWidgets('read-receipt requests are pointed out, never answered', (
    tester,
  ) async {
    app.seedFixture(
      'people/read-receipt-requested.eml',
      subject: 'Receipt please',
      uid: 72,
    );
    await show(tester);
    await open(tester, 'Receipt please');
    expect(
      find.textContaining('asked to be told when you read this'),
      findsOneWidget,
    );
    expect(
      app.store.outbox
          .all(app.store.accounts.all().single.id)
          .map((e) => e.action)
          .whereType<SendAction>(),
      isEmpty,
    );
  });

  testWidgets('links open without their tracking parameters', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => LinkOpener.open(
              context,
              Uri.parse(
                'https://shop.example/deals?utm_source=newsletter'
                '&utm_medium=email&uid=abc123',
              ),
              onMailto: (_) {},
            ),
            child: const Text('link'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is SelectableText &&
            w.data == 'https://shop.example/deals?uid=abc123',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Tracking removed from the link: utm_source, utm_medium.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Settings lists image senders and removes them', (tester) async {
    app.store.imageSenders.allow('news@shop.example');
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(services: app.services, isAndroid: false)),
    );
    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.text('news@shop.example'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(app.store.imageSenders.all(), isEmpty);
  });
}
