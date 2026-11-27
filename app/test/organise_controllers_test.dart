// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Old codes, unsubscribing, blocking and the Screener on their own: their
// controllers without the mail screen.

import 'package:citusmail/src/features/reader/state/reader_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';

import 'support/controllers.dart';
import 'support/test_app.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

void main() {
  late TestApp app;
  late Controllers c;
  setUp(() async {
    app = await TestApp.create();
    c = Controllers(app);
  });
  tearDown(() {
    c.dispose();
    return app.dispose();
  });

  bool inInbox(String subject) => c.store.messages
      .list(MessageQuery(mailboxIds: [c.box('INBOX').id], limit: 100))
      .any((m) => m.subject == subject);

  /// The sample mail the user sent.
  StoredMessage ownSent() => c.store.messages
      .list(MessageQuery(mailboxIds: [c.box('Sent').id]))
      .single;

  group('OldCodesController', () {
    void code(int uid, String subject, Duration age) =>
        c.store.messages.upsertSummaries(c.box('INBOX').id, [
          MessageSummary(
            uid: uid,
            messageId: '<code$uid@accounts.shop.example>',
            receivedAt: DateTime.now().toUtc().subtract(age),
            subject: subject,
            from: _address('no-reply@accounts.shop.example', 'Shop'),
            category: MessageCategory.codes,
            code: '482913',
          ),
        ]);

    test('asks first; nothing moves before the answer', () {
      code(20, 'Your code', const Duration(days: 3));
      code(21, 'Reset your password', const Duration(days: 2));
      c.oldCodes.refreshOffer();
      expect(c.oldCodes.codesOffer.value, isTrue);
      c.oldCodes.tidy();
      expect(inInbox('Reset your password'), isTrue);
      expect(c.notices, isEmpty);
    });

    test('"Not now" stops asking', () {
      code(20, 'Your code', const Duration(days: 3));
      c.oldCodes.refreshOffer();
      c.oldCodes.decline();
      expect(c.oldCodes.codesOffer.value, isFalse);
      c.oldCodes.refreshOffer();
      expect(c.oldCodes.codesOffer.value, isFalse);
    });

    test('"Turn on" tidies up now, keeping the open message, with Undo', () {
      code(20, 'Your code', const Duration(days: 3));
      code(21, 'Reset your password', const Duration(days: 2));
      code(22, 'Kept open', const Duration(days: 2));
      c.reader.reader.value = ReaderLoading(c.message('Kept open'));

      c.oldCodes.agree();
      expect(c.lastNotice, 'Tidied up 2 old codes');
      expect(inInbox('Reset your password'), isFalse);
      expect(inInbox('Kept open'), isTrue, reason: 'open');
      expect(c.oldCodes.codesOffer.value, isFalse);

      c.undoLast();
      expect(inInbox('Reset your password'), isTrue);
    });
  });

  group('UnsubscribeController', () {
    test(
      'a web page unsubscribe is remembered and can archive the list',
      () async {
        final message = app.seedFixture(
          'newsletters/one-click-unsubscribe.eml',
          subject: '50% off everything this week',
          uid: 70,
        );
        await c.reader.open(message);
        final ready = c.reader.reader.value as ReaderReady;
        expect(c.unsubscribe.sameList(ready), hasLength(1));

        final problem = await c.unsubscribe.unsubscribe(
          ready,
          WebPageMethod(Uri.parse('https://shop.example/unsub')),
          archiveList: true,
        );
        expect(problem, isNull);
        expect(
          c.lastNotice,
          'Opened the unsubscribe page for Shop Weekly. Archived 1.',
        );
        final record = c.store.unsubscriptions.find(
          c.accountId,
          'list:weekly.shop.example',
        );
        expect(record?.kind, UnsubscribeKind.webPage);
        expect(c.reader.unsubscriptionFor(message)?.listName, 'Shop Weekly');
        // The next message opens in place of the archived one.
        for (
          var i = 0;
          i < 100 && c.reader.reader.value is ReaderLoading;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(c.reader.selected?.id, isNot(message.id));
      },
    );

    test('the open message shows it at once', () async {
      final message = app.seedFixture(
        'newsletters/one-click-unsubscribe.eml',
        subject: '50% off everything this week',
        uid: 70,
      );
      await c.reader.open(message);
      final ready = c.reader.reader.value as ReaderReady;
      await c.unsubscribe.unsubscribe(
        ready,
        WebPageMethod(Uri.parse('https://shop.example/unsub')),
      );
      expect(c.lastNotice, 'Opened the unsubscribe page for Shop Weekly');
      final now = c.reader.reader.value as ReaderReady;
      expect(now.unsubscribed?.kind, UnsubscribeKind.webPage);
    });
  });

  group('BlockingController', () {
    test('own mail can\'t be blocked; free mail offers no domain', () {
      final sent = ownSent();
      expect(c.blocking.canBlock(sent), isFalse);
      expect(c.blocking.blockChoice(sent), isNull);
      final choice = c.blocking.blockChoice(c.message('Hello there'))!;
      expect(choice.address, 'stranger@x.example');
      expect(choice.fromAddress, 1);
    });

    test('blocking moves their mail to Junk, with Undo', () {
      c.blocking.block(BlockKind.address, 'carol@x.example');
      expect(c.lastNotice, 'Blocked carol@x.example. Moved 1 to Junk.');
      expect(inInbox('Lunch?'), isFalse);
      expect(c.blocking.blockFor(c.message('Hello there')), isNull);
      c.undoLast();
      expect(inInbox('Lunch?'), isTrue);
      expect(c.store.blocks.all(), isEmpty);
    });

    test('blocking without moving, then unblocking', () {
      c.blocking.block(
        BlockKind.address,
        'carol@x.example',
        moveExisting: false,
      );
      expect(c.lastNotice, 'Blocked carol@x.example');
      final block = c.blocking.blockFor(c.message('Lunch?'))!;
      c.blocking.unblock(block);
      expect(c.lastNotice, 'Unblocked carol@x.example');
      expect(c.blocking.blockFor(c.message('Lunch?')), isNull);
    });
  });

  group('ScreenerController', () {
    void seed() {
      c.store.screener.enable(now: DateTime.utc(2026, 10, 21));
      c.store.messages.upsertSummaries(c.box('INBOX').id, [
        MessageSummary(
          uid: 20,
          receivedAt: DateTime.utc(2026, 10, 22, 8),
          subject: 'Portfolio review?',
          from: _address('ana@studio.example', 'Ana Ruiz'),
          messageId: 'ana1@studio.example',
        ),
        MessageSummary(
          uid: 21,
          receivedAt: DateTime.utc(2026, 10, 22, 10),
          subject: 'Exclusive offer, today only',
          from: _address('promo@deals.example', 'Deals Daily'),
          messageId: 'promo1@deals.example',
        ),
      ]);
    }

    test('first-time senders, only while the Screener is off', () {
      expect(c.screener.isFirstTimeSender(c.message('Hello there')), isTrue);
      expect(c.screener.isFirstTimeSender(ownSent()), isFalse);
      seed();
      expect(c.screener.isFirstTimeSender(c.message('Hello there')), isFalse);
    });

    test('a company domain, never free mail', () {
      expect(c.screener.screenerDomain('ana@studio.example'), 'studio.example');
      expect(c.screener.screenerDomain('someone@gmail.com'), isNull);
      expect(c.screener.screenerDomain('bob@citusmail.test'), isNull);
    });

    test('letting in, with Undo', () {
      seed();
      final ana = c.screener.waitingSenders().firstWhere(
        (w) => w.address == 'ana@studio.example',
      );
      c.screener.letIn(ana);
      expect(c.lastNotice, 'Ana Ruiz can now reach your inbox');
      expect(
        c.screener.waitingSenders().map((w) => w.address),
        isNot(contains('ana@studio.example')),
      );
      c.undoLast();
      expect(
        c.screener.waitingSenders().map((w) => w.address),
        contains('ana@studio.example'),
      );
    });

    test('screened out to Archive moves the waiting mail', () {
      seed();
      c.store.screener.outPlace = ScreenOutPlace.archive;
      final promo = c.screener.waitingSenders().firstWhere(
        (w) => w.address == 'promo@deals.example',
      );
      c.screener.screenOut(promo);
      expect(c.lastNotice, 'Deals Daily screened out. Moved to Archive.');
      expect(inInbox('Exclusive offer, today only'), isFalse);
    });

    test('screened out elsewhere says where', () {
      seed();
      c.store.screener.outPlace = ScreenOutPlace.newsletters;
      final promo = c.screener.waitingSenders().firstWhere(
        (w) => w.address == 'promo@deals.example',
      );
      c.screener.screenOut(promo, wholeDomain: true);
      expect(
        c.lastNotice,
        'Everyone at deals.example screened out. Their mail goes to '
        'Newsletters.',
      );
    });
  });
}
