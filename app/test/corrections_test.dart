// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/corrections.dart';
import 'package:citusmail/src/mail/subscriptions_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  /// GitHub notifications about billing code (the rules take them for a
  /// subscription), one like them from Codeberg, and real receipts.
  void seed() {
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    final now = DateTime.now().toUtc();
    const footer =
        '\n\n—\nReply to this email directly, view it on GitHub, or '
        'unsubscribe. You are receiving this because you were mentioned.';
    app.store.messages.upsertSummaries(inbox.id, [
      for (final (i, (subject, text)) in [
        (
          '[acme/payments] Invoice PDF is missing the tax line (#311)',
          'The invoice PDF generated for annual subscriptions drops the GST '
              'line. @alexlim can you take a look?',
        ),
        (
          '[acme/payments] Receipt emails sent twice after renewal (#318)',
          'After a subscription renewal the receipt job runs twice and '
              'customers get two receipts.',
        ),
        (
          '[acme/web] Billing page shows the wrong plan (#902)',
          'On the billing page the plan name is cached. Steps to '
              'reproduce: renew the subscription, reload.',
        ),
      ].indexed)
        MessageSummary(
          uid: 400 + i,
          receivedAt: now.subtract(Duration(days: 10 + 20 * i)),
          subject: subject,
          from: const MailAddress(
            displayName: 'Mei Chen',
            localPart: 'notifications',
            domain: 'github.com',
          ),
          snippet: '$text$footer',
        ),
      MessageSummary(
        uid: 410,
        receivedAt: now.subtract(const Duration(days: 4)),
        subject: '[acme/infra] Invoice export job times out (#57)',
        from: const MailAddress(
          displayName: 'Jonas W',
          localPart: 'notifications',
          domain: 'codeberg.org',
        ),
        snippet:
            'The nightly invoice export for subscriptions times out after '
            '30 minutes. @alexlim assigned.\n\n—\nReply to this email '
            'directly or view it on Codeberg. You are receiving this because '
            'you were mentioned.',
      ),
      for (final (i, daysAgo) in [3, 33, 63].indexed)
        MessageSummary(
          uid: 420 + i,
          receivedAt: now.subtract(Duration(days: daysAgo)),
          subject: 'Your receipt from Anthropic, PBC #2841-331$i',
          from: const MailAddress(
            displayName: 'Anthropic, PBC',
            localPart: 'invoice+statements',
            domain: 'mail.anthropic.com',
          ),
          snippet:
              'Receipt from Anthropic, PBC. Amount paid \$20.00. Claude Pro '
              'subscription, renews monthly. Payment method Visa - 4242.',
        ),
    ]);
  }

  Future<SubscriptionsModel> loaded() async {
    final model = SubscriptionsModel(app.services);
    await model.load();
    return model;
  }

  /// Lets the reload after a change finish.
  Future<void> settle(SubscriptionsModel model) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await model.load();
  }

  List<String> listed(SubscriptionsModel m) =>
      [for (final s in m.subscriptions) s.company]..sort();

  test('nothing learned: exactly what the rules find', () async {
    seed();
    final model = await loaded();
    expect(listed(model), ['anthropic.com', 'codeberg.org', 'github.com']);
    expect(model.learned, isEmpty);
    expect(Corrections(app.store).learnedAnything, isFalse);
  });

  test(
    '"Not a subscription" on GitHub leaves out the look-alike only',
    () async {
      seed();
      final model = await loaded();
      model.hide('github.com');
      await settle(model);
      expect(listed(model), ['anthropic.com']);
      expect(model.hidden, {'github.com'});
      expect(model.learned, {'codeberg.org'});
      expect([for (final s in model.hiddenOnes) s.company]..sort(), [
        'codeberg.org',
        'github.com',
      ]);

      // "List again": listed, and never left out again.
      model.unhide('codeberg.org');
      await settle(model);
      expect(listed(model), ['anthropic.com', 'codeberg.org']);
      expect(model.learned, isEmpty);
      await settle(model);
      expect(listed(model), ['anthropic.com', 'codeberg.org']);
    },
  );

  test('Undo takes the correction back', () async {
    seed();
    final model = await loaded();
    model.hide('github.com');
    await settle(model);
    model.unhide('github.com');
    await settle(model);
    expect(listed(model), ['anthropic.com', 'codeberg.org', 'github.com']);
    expect(Corrections(app.store).learnedAnything, isFalse);
  });

  test(
    'off: nothing learned or left out; forgetting lists all again',
    () async {
      seed();
      app.services.settings.learnFromCorrections = false;
      var model = await loaded();
      model.hide('github.com');
      await settle(model);
      expect(listed(model), ['anthropic.com', 'codeberg.org']);
      expect(Corrections(app.store).learnedAnything, isFalse);
      model.unhide('github.com');

      app.services.settings.learnFromCorrections = true;
      model = await loaded();
      model.hide('github.com');
      await settle(model);
      expect(model.learned, {'codeberg.org'});
      // Turned off again: listed, and the learning is kept for later.
      app.services.settings.learnFromCorrections = false;
      await settle(model);
      expect(model.learned, isEmpty);
      app.services.settings.learnFromCorrections = true;
      await settle(model);
      expect(model.learned, {'codeberg.org'});

      Corrections(app.store).forget();
      await settle(model);
      expect(listed(model), ['anthropic.com', 'codeberg.org']);
      expect(model.hidden, {'github.com'}, reason: 'marked by the user');
    },
  );
}
