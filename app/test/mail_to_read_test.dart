// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Which emails each page would download to fill itself in: the same
// functions serve the pages and reading in the background.

import 'dart:convert';

import 'package:citusmail/src/mail/accounts_model.dart';
import 'package:citusmail/src/mail/deliveries_model.dart';
import 'package:citusmail/src/mail/subscriptions_model.dart';
import 'package:citusmail/src/mail/trips_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late StoredMailbox inbox;
  final now = DateTime.now().toUtc();
  var uid = 400;

  setUp(() async {
    app = await TestApp.create();
    inbox = app.store.mailboxes.inbox(app.store.accounts.all().single.id)!;
  });
  tearDown(() => app.dispose());

  /// An inbox message [daysAgo] old; returns its id.
  int add(
    String subject,
    String from, {
    String? name,
    String? snippet,
    int daysAgo = 2,
    int size = 20000,
    MessageCategory category = MessageCategory.notifications,
  }) {
    final at = ++uid;
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: at,
        receivedAt: now.subtract(Duration(days: daysAgo)),
        subject: subject,
        from: MailAddress(
          displayName: name,
          localPart: from.split('@').first,
          domain: from.split('@').last,
        ),
        snippet: snippet,
        size: size,
        category: category,
      ),
    ]);
    return app.store.messages.byUid(inbox.id, at)!.id;
  }

  void download(int id) => app.store.messages.saveBody(
    id,
    utf8.encode('Subject: x\r\n\r\nThanks.\r\n'),
    searchableText: 'Thanks.',
  );

  group('Subscriptions', () {
    Future<List<int>> toRead({Set<int> skip = const {}}) async =>
        (await findSubscriptions(
          app.store,
          now,
          monthlyRenewals: false,
          skip: skip,
        )).toRead;

    test('receipts whose price is missing, not those already known', () async {
      // Priced in the preview: nothing to read.
      for (final days in [5, 35, 65]) {
        add(
          'Your StreamFlix receipt',
          'info@mailer.streamflix.example',
          name: 'StreamFlix',
          snippet: 'Your membership has been renewed. Total S\$17.98',
          daysAgo: days,
        );
      }
      // A receipt from a company not recognised yet: its whole text may
      // show a billing period.
      final unknown = add(
        'Your receipt from CloudBox',
        'billing@cloudbox.example',
        name: 'CloudBox',
        snippet: 'Thanks for your payment.',
      );
      // Too big to download quietly.
      add(
        'Your receipt from PhotoVault',
        'billing@photovault.example',
        snippet: 'Thanks for your payment.',
        size: 2 * 1024 * 1024,
      );
      // A reply about a receipt is not one.
      add(
        'Re: Your receipt from CloudBox',
        'billing@cloudbox.example',
        snippet: 'Thanks for your payment.',
      );
      // Ordinary mail: no subscription words at all.
      add('Lunch on Friday?', 'carol@x.example', snippet: 'Noodles?');

      expect(await toRead(), [unknown]);
      expect(await toRead(skip: {unknown}), isEmpty);
      download(unknown);
      expect(await toRead(), isEmpty, reason: 'on the device now');
    });

    test('a company the user said is not a subscription is left out', () async {
      add(
        'Your receipt from CloudBox',
        'billing@cloudbox.example',
        snippet: 'Thanks for your payment.',
      );
      app.store.settings.write(
        SubscriptionsModel.hiddenKey,
        'cloudbox.example',
      );
      expect(await toRead(), isEmpty);
    });
  });

  group('Trips', () {
    test('booking mail not understood yet; newsletters never', () async {
      final booking = add(
        'Your booking confirmation for Hotel Sakura',
        'reservations@stays.example',
        name: 'Stays',
        snippet: 'Thank you for booking with us.',
      );
      add(
        'Book your summer flights now: 20% off',
        'deals@airline.example',
        snippet: 'Our best fares.',
        category: MessageCategory.newsletters,
      );
      add(
        'Your booking confirmation for Hotel Kyoto',
        'reservations@stays.example',
        snippet: 'Thank you for booking with us.',
        size: 3 * 1024 * 1024,
      );
      add('Weekend plans', 'carol@x.example', snippet: 'Hiking?');

      final found = await findTrips(app.store, now);
      expect(found.toRead, [booking]);
      expect(
        (await findTrips(app.store, now, skip: {booking})).toRead,
        isEmpty,
      );
    });
  });

  group('Deliveries', () {
    test('shipping mail without a tracking number or date', () async {
      final shipped = add(
        'Your order has shipped',
        'orders@shop.example',
        name: 'Shop',
        snippet: 'Good news! Your package is on its way.',
      );
      add(
        'Free shipping on everything this weekend',
        'news@shop.example',
        snippet: 'Shop now.',
        category: MessageCategory.newsletters,
      );
      add('Shipping the book back to you', 'carol@x.example', size: 900000);

      final found = await findDeliveries(app.store, now);
      // (The sample inbox's "Your parcel" too.)
      expect(found.toRead, contains(shipped));
      expect(found.toRead, hasLength(2));
      expect(
        (await findDeliveries(app.store, now, skip: {shipped})).toRead,
        isNot(contains(shipped)),
      );
      download(shipped);
      expect((await findDeliveries(app.store, now)).toRead, hasLength(1));
    });
  });

  group('Online accounts', () {
    test('a welcome email that says too little in its preview', () async {
      final welcome = add(
        'Welcome!',
        'hello@paperboard.example',
        name: 'Paperboard',
        snippet: 'We are glad to have you.',
        category: MessageCategory.newsletters,
      );
      // From a person: not an account email.
      add(
        'Welcome to the team',
        'dave@gmail.com',
        name: 'Dave',
        snippet: 'Great to have you here.',
      );

      final found = await findOnlineAccounts(app.store, now);
      expect(found.toRead, [welcome]);
      expect(
        (await findOnlineAccounts(app.store, now, skip: {welcome})).toRead,
        isEmpty,
      );
    });
  });
}
