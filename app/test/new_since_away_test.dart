// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/new_since_away.dart';
import 'package:citusmail/src/services/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// Alice closed the app on Tuesday evening and opened it again on
/// Wednesday morning.
final _left = DateTime.utc(2026, 11, 3, 18, 30);
final _back = DateTime.utc(2026, 11, 4, 8, 5);

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() {
    NewSinceAway.clock = DateTime.now;
    return app.dispose();
  });

  MailStore store() => app.store;
  StoredMailbox inbox() =>
      store().mailboxes.inbox(store().accounts.all().single.id)!;
  NewSinceAway away() => NewSinceAway(store());
  List<String> subjects(NewMail mail) => [
    for (final m in mail.messages) m.subject ?? '',
  ];

  /// What came in overnight, and around it.
  void seedNight() {
    var uid = 30;
    MessageSummary mail(
      DateTime at,
      String from,
      String name,
      String subject, {
      MessageCategory category = MessageCategory.general,
      String? code,
      bool seen = false,
    }) => MessageSummary(
      uid: uid++,
      receivedAt: at,
      subject: subject,
      from: _address(from, name),
      category: category,
      code: code,
      messageId: 'night$uid@x.example',
      flags: MessageFlags.fromImap([if (seen) r'\Seen']),
    );
    store().messages.upsertSummaries(inbox().id, [
      // Exactly when she left: she had seen it come in.
      mail(_left, 'carol@x.example', 'Carol', 'Before you go'),
      mail(
        _left.add(const Duration(minutes: 1)),
        'carol@x.example',
        'Carol',
        'Dinner on Friday?',
      ),
      mail(
        DateTime.utc(2026, 11, 3, 22, 15),
        'priya@fabrikam.example',
        'Priya Shah',
        'Contract draft, v3',
        seen: true, // read on her phone
      ),
      // A note she mailed herself from her phone.
      mail(
        DateTime.utc(2026, 11, 4, 2),
        'alice@citusmail.test',
        'Alice',
        'Passport number for the booking',
      ),
      mail(
        DateTime.utc(2026, 11, 4, 3),
        'digest@medium.example',
        'Medium Daily Digest',
        'Stories picked for you',
        category: MessageCategory.newsletters,
      ),
      mail(
        DateTime.utc(2026, 11, 4, 4),
        'news@shop.example',
        'Shop',
        'Last chance: 40% off boots',
        category: MessageCategory.newsletters,
      ),
      mail(
        DateTime.utc(2026, 11, 4, 4, 30),
        'shipping@parcel.example',
        'Parcel Co',
        'Your order has shipped',
        category: MessageCategory.notifications,
      ),
      mail(
        DateTime.utc(2026, 11, 4, 5),
        'winner@cheap-pills.example',
        'Pharmacy',
        'You have been selected!!!',
      ),
      mail(
        DateTime.utc(2026, 11, 4, 6),
        'no-reply@northwind.example',
        'Northwind Bank',
        'Your sign-in code',
        category: MessageCategory.codes,
        code: '482913',
      ),
    ]);
    store().blocks.block(BlockKind.domain, 'cheap-pills.example');
    // The Screener holds back someone writing for the first time.
    store().screener.enable(now: DateTime.utc(2026, 11, 4, 6, 30));
    store().messages.upsertSummaries(inbox().id, [
      mail(
        DateTime.utc(2026, 11, 4, 7),
        'recruiter@talent.example',
        'Jordan at Talent',
        'Quick question about your next move',
      ),
      // Right as she opened the app.
      mail(_back, 'dave@x.example', 'Dave', 'Standup moved to 10'),
      // While she was reading: goes to General as usual.
      mail(
        _back.add(const Duration(minutes: 1)),
        'dave@x.example',
        'Dave',
        'Never mind, 9:30',
      ),
    ]);
    expect(
      store().messages
          .list(const MessageQuery.inbox(limit: 100))
          .firstWhere((m) => m.subject!.startsWith('Quick question'))
          .section,
      SmartSection.screener,
    );
  }

  NewMail backAt(DateTime at) {
    final a = away()..wentAway(_left);
    expect(a.cameBack(at), isTrue);
    return a.mail();
  }

  group('which mail', () {
    test('received after leaving, up to coming back', () {
      seedNight();
      final mail = backAt(_back);
      expect(subjects(mail), [
        'Standup moved to 10',
        'Contract draft, v3',
        'Dinner on Friday?',
      ]);
      expect(mail.since, _left);
      // Read elsewhere: still listed, shown as read.
      expect(mail.unread, 2);
    });

    test('not her own mail, blocked senders, the Screener or codes', () {
      seedNight();
      final mail = backAt(_back);
      for (final left in [
        'Passport number for the booking',
        'You have been selected!!!',
        'Quick question about your next move',
        'Your sign-in code',
      ]) {
        expect(subjects(mail), isNot(contains(left)));
      }
      final codes = store().messages
          .list(const MessageQuery.smart(SmartSection.codes))
          .map((m) => m.subject);
      expect(codes, contains('Your sign-in code'));
    });

    test('newsletters and notifications are only counted', () {
      seedNight();
      final mail = backAt(_back);
      expect(mail.newsletters, 2);
      expect(mail.notifications, 1);
      expect(subjects(mail), isNot(contains('Stories picked for you')));
    });

    test('the boundaries: after leaving, until coming back', () {
      final window = AwayWindow(_left, _back);
      expect(window.contains(_left), isFalse);
      expect(window.contains(_left.add(const Duration(seconds: 1))), isTrue);
      expect(window.contains(_back), isTrue);
      expect(window.contains(_back.add(const Duration(seconds: 1))), isFalse);
    });

    test('nothing new: no section', () {
      final mail = backAt(_back);
      expect(mail.isEmpty, isTrue);
      expect(mail.since, isNull);
    });

    test('only newsletters: no section', () {
      store().messages.upsertSummaries(inbox().id, [
        MessageSummary(
          uid: 60,
          receivedAt: DateTime.utc(2026, 11, 4, 3),
          subject: 'This week in gardening',
          from: _address('news@garden.example', 'Garden Weekly'),
          category: MessageCategory.newsletters,
        ),
      ]);
      expect(backAt(_back).isEmpty, isTrue);
    });
  });

  group('when it resets', () {
    test('the very first run has no section', () {
      final a = away();
      expect(a.cameBack(_back), isFalse);
      expect(a.window, isNull);
    });

    test('back after more than a minute: the section is rebuilt', () {
      final a = away()..wentAway(_left);
      expect(a.cameBack(_back), isTrue);
      expect(a.window!.since, _left);
      expect(a.window!.until, _back);

      // Away again for an hour.
      final later = _back.add(const Duration(hours: 2));
      a.wentAway(later);
      expect(a.cameBack(later.add(const Duration(hours: 1))), isTrue);
      expect(a.window!.since, later);
    });

    test('back after 30 seconds: the section stays as it was', () {
      final a = away()..wentAway(_left);
      a.cameBack(_back);
      final glance = _back.add(const Duration(minutes: 20));
      a.wentAway(glance);
      expect(a.cameBack(glance.add(const Duration(seconds: 30))), isFalse);
      expect(a.window!.since, _left);
      expect(a.window!.until, _back);
    });

    test('leaving survives the app being closed', () {
      away().wentAway(_left);
      expect(store().settings.read(NewSinceAway.awayKey), isNotNull);
      // A fresh start reads what was kept, and forgets it.
      NewSinceAway.clock = () => _back;
      final a = away();
      expect(a.cameBack(), isTrue);
      expect(a.window!.since, _left);
      expect(store().settings.read(NewSinceAway.awayKey), isNull);
    });

    test('going away twice keeps the first time', () {
      final a = away()..wentAway(_left);
      a.wentAway(_left.add(const Duration(hours: 3)));
      a.cameBack(_back);
      expect(a.window!.since, _left);
    });

    test('Done clears it until the next time', () {
      seedNight();
      final a = away()..wentAway(_left);
      a.cameBack(_back);
      expect(a.mail().isEmpty, isFalse);
      a.done();
      expect(a.window, isNull);
      expect(a.mail().isEmpty, isTrue);
      // Nothing changed on the messages themselves.
      final dinner = store().messages
          .list(const MessageQuery.inbox(limit: 100))
          .firstWhere((m) => m.subject == 'Dinner on Friday?');
      expect(dinner.flags.seen, isFalse);
      expect(
        dinner.section,
        SmartSection.important,
      ); // Carol: she writes to her
    });

    test('with the setting off there is no section', () {
      seedNight();
      AppSettings(store()).newSinceAway = false;
      final a = away()..wentAway(_left);
      a.cameBack(_back);
      expect(a.mail().isEmpty, isTrue);
      AppSettings(store()).newSinceAway = true;
      expect(subjects(a.mail()), hasLength(3));
    });
  });
}
