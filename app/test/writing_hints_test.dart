// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/compose/state/compose_controller.dart';
import 'package:citusmail/src/features/compose/state/send_later_times.dart';
import 'package:citusmail/src/features/compose/state/writing_hints.dart';
import 'package:citusmail/src/features/compose/ui/compose_page.dart';
import 'package:citusmail/src/features/compose/ui/recipient_field.dart';
import 'package:citusmail/src/features/compose/ui/send_later_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

MailDate _date(int hours, {bool known = true}) => MailDate(
  DateTime.utc(2026, 11, 1),
  Duration(hours: hours),
  zoneKnown: known,
);

const _maya = MailAddress(
  displayName: 'Maya Lin',
  localPart: 'maya',
  domain: 'example.com',
);
const _sam = MailAddress(
  displayName: 'Sam Ortiz',
  localPart: 'sam',
  domain: 'studio.example',
);
const _lee = MailAddress(
  displayName: 'Lee Park',
  localPart: 'lee',
  domain: 'far.example',
);
const _list = MailAddress(localPart: 'dev', domain: 'lists.example.org');

/// Thursday 5 November 2026, 7:40 UTC: 11:40 PM on Wednesday for Maya
/// (UTC-8), 8:40 AM for Lee (UTC+1).
final _night = DateTime.utc(2026, 11, 5, 7, 40);

/// 18:00 UTC: 10:00 AM for Maya.
final _day = DateTime.utc(2026, 11, 5, 18);

void main() {
  group('the rules', () {
    test('their usual offset: the most common, when consistent', () {
      expect(
        HintRules.usualOffset([for (var i = 0; i < 5; i++) _date(-8)]),
        (const Duration(hours: -8)),
      );
      // 7 of 10 is enough; 6 of 10 is not.
      expect(
        HintRules.usualOffset([
          for (var i = 0; i < 7; i++) _date(-8),
          for (var i = 0; i < 3; i++) _date(-7),
        ]),
        const Duration(hours: -8),
      );
      expect(
        HintRules.usualOffset([
          for (var i = 0; i < 6; i++) _date(-8),
          for (var i = 0; i < 4; i++) _date(-7),
        ]),
        isNull,
      );
    });

    test('their usual offset needs at least 3 emails', () {
      expect(HintRules.usualOffset([_date(-8), _date(-8)]), isNull);
      expect(
        HintRules.usualOffset([_date(-8), _date(-8), _date(-8)]),
        (const Duration(hours: -8)),
      );
    });

    test('UTC and unknown zones say nothing, and count against it', () {
      expect(
        HintRules.usualOffset([for (var i = 0; i < 5; i++) _date(0)]),
        (isNull),
      );
      expect(
        HintRules.usualOffset([
          for (var i = 0; i < 5; i++) _date(-8, known: false),
        ]),
        isNull,
      );
      expect(
        HintRules.usualOffset([
          for (var i = 0; i < 3; i++) _date(-8),
          for (var i = 0; i < 3; i++) _date(0),
        ]),
        isNull,
      );
    });

    test('reply time: the median, with at least 3 replies', () {
      const h = Duration(hours: 1);
      expect(HintRules.medianDelay([h, h * 2]), isNull);
      expect(HintRules.medianDelay([h * 9, h, h * 2]), h * 2);
      expect(HintRules.medianDelay([h, h * 2, h * 4, h * 30]), h * 3);
      expect(
        HintRules.replySentence('Maya', h * 2),
        'Maya usually replies within 2 hours.',
      );
      expect(
        HintRules.replySentence('Maya', const Duration(minutes: 20)),
        'Maya usually replies within an hour.',
      );
      expect(
        HintRules.replySentence('Maya', h * 30),
        'Maya usually replies within 2 days.',
      );
      expect(
        HintRules.replySentence('Maya', h * 24 * 10),
        'Maya usually takes more than a week to reply.',
      );
    });

    test('night is from 10 pm to 7 am', () {
      for (final (hour, night) in [
        (21, false),
        (22, true),
        (3, true),
        (6, true),
        (7, false),
        (12, false),
      ]) {
        expect(
          HintRules.isNight(DateTime.utc(2026, 11, 5, hour)),
          night,
          reason: '$hour',
        );
      }
    });

    test('8:00 in their morning: tomorrow late in the evening, else today', () {
      const hint = LocalTimeHint(names: ['Maya'], offset: Duration(hours: -8));
      // 11:40 PM on the 4th for Maya: 8:00 on the 5th, 16:00 UTC.
      expect(hint.morning(_night), DateTime.utc(2026, 11, 5, 16));
      expect(hint.morningIsTomorrow(_night), isTrue);
      // 2:00 AM on the 5th for Maya: still 8:00 on the 5th.
      final small = DateTime.utc(2026, 11, 5, 10);
      expect(hint.morning(small), DateTime.utc(2026, 11, 5, 16));
      expect(hint.morningIsTomorrow(small), isFalse);
    });

    test('a near miss: one character off, or the same name elsewhere', () {
      const known = [
        _maya,
        _sam,
        MailAddress(localPart: 'jo', domain: 'company.example'),
      ];
      String? miss(String typed) => HintRules.nearMiss(typed, known)?.address;
      expect(miss('maya@exmaple.com'), 'maya@example.com');
      expect(miss('maia@example.com'), 'maya@example.com');
      expect(miss('mayaa@example.com'), 'maya@example.com');
      expect(miss('maya@example.co'), 'maya@example.com');
      expect(miss('maya@example.org'), 'maya@example.com');
      expect(miss('sam@studoi.example'), 'sam@studio.example');
      // Genuinely new people.
      expect(miss('priya@example.com'), isNull);
      expect(miss('jo@gmail.com'), isNull);
      expect(miss('maya@otherco.example'), isNull);
      // A known address itself.
      expect(miss('maya@example.com'), isNull);
    });

    test('names: the first name, else the address', () {
      expect(HintRules.shortName(_maya), 'Maya');
      expect(
        HintRules.shortName(
          const MailAddress(localPart: 'm', domain: 'x.example'),
          'Lin, Maya',
        ),
        'Maya',
      );
      expect(
        HintRules.shortName(
          const MailAddress(localPart: 'm', domain: 'x.example'),
        ),
        'm@x.example',
      );
      expect(HintRules.names(['Maya', 'Sam']), 'Maya and Sam');
      expect(HintRules.names(['Maya', 'Sam', 'Lee']), 'Maya and 2 others');
    });
  });

  test('the setting: on by default, the same on every device', () async {
    final app = await TestApp.create();
    addTearDown(app.dispose);
    expect(app.services.settings.writingHints, isTrue);
    app.services.settings.writingHints = false;
    expect(app.services.settings.writingHints, isFalse);
    expect(SyncedPreferences.preferenceOf('writing.hints'), 'writing.hints');
    expect(
      SyncedPreferences(app.store.database).changedAt('writing.hints'),
      isNotNull,
    );
  });

  group('in the compose window', () {
    late TestApp app;
    late ComposeController controller;

    setUp(() async {
      app = await TestApp.create();
      SendLaterTimes.clock = () => _night;
    });
    tearDown(() {
      SendLaterTimes.clock = DateTime.now;
      app.dispose();
    });

    int accountId() => app.store.accounts.all().single.id;
    StoredMailbox inbox() => app.store.mailboxes.inbox(accountId())!;
    StoredMailbox sent() =>
        app.store.mailboxes.bySpecialUse(accountId(), SpecialUse.sent)!;

    const alice = MailAddress(localPart: 'alice', domain: 'citusmail.test');
    var uid = 100;

    /// [count] emails from [who], dated at [hours] from UTC; with
    /// [replies], the user's emails they answered after 1, 2 and 3 hours.
    void mailFrom(
      MailAddress who, {
      int hours = -8,
      int count = 5,
      bool replies = false,
      String? listId,
    }) {
      for (var i = 0; i < count; i++) {
        final at = DateTime.utc(2026, 10, 1 + i, 18);
        app.store.messages.upsertSummaries(inbox().id, [
          MessageSummary(
            uid: ++uid,
            receivedAt: at,
            sentAt: at,
            messageId: 'm$uid@${who.domain}',
            from: who,
            to: const [alice],
            listId: listId,
            headers: {
              'date': [MailDate.format(at, offset: Duration(hours: hours))],
            },
          ),
        ]);
      }
      if (!replies) return;
      for (var i = 1; i <= 3; i++) {
        final asked = DateTime.utc(2026, 10, 20 + i, 9);
        app.store.messages.upsertSummaries(sent().id, [
          MessageSummary(
            uid: ++uid,
            receivedAt: asked,
            sentAt: asked,
            messageId: 's$uid@citusmail.test',
            from: alice,
            to: [who],
          ),
        ]);
        app.store.messages.upsertSummaries(inbox().id, [
          MessageSummary(
            uid: uid + 1000,
            receivedAt: asked.add(Duration(hours: i)),
            sentAt: asked.add(Duration(hours: i)),
            messageId: 'r$uid@${who.domain}',
            inReplyTo: 's$uid@citusmail.test',
            from: who,
            to: const [alice],
          ),
        ]);
      }
    }

    ComposeResult? result;

    Future<void> open(
      WidgetTester tester, {
      List<MailAddress> to = const [],
      Size size = const Size(1200, 900),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller = ComposeController(
        app.services,
        Draft(accountId: accountId(), to: to),
      );
      addTearDown(controller.dispose);
      result = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => result = await Navigator.of(context)
                      .push<ComposeResult>(
                        MaterialPageRoute(
                          builder: (_) => ComposePage(controller: controller),
                        ),
                      ),
                  child: const Text('Write'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
    }

    /// Lets the hints be worked out and shown.
    Future<void> hints(WidgetTester tester) async {
      await tester.pump(Duration.zero);
      await tester.pump();
    }

    Finder toField() => find.descendant(
      of: find.byType(RecipientField).first,
      matching: find.byType(TextField),
    );

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(toField(), text);
      await hints(tester);
    }

    final hint = find.byKey(const ValueKey('writing-hint'));

    Future<void> finish(WidgetTester tester) async {
      // Let the draft's save timer run out.
      await tester.pump(ComposeController.autosaveDelay);
    }

    testWidgets('late at night for them: Send later, 8:00 AM their time', (
      tester,
    ) async {
      mailFrom(_maya);
      await open(tester);
      await type(tester, 'Maya Lin <maya@example.com>,');
      expect(find.text('It\'s 11:40 PM for Maya. Send later?'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('writing-hint-action')));
      await tester.pumpAndSettle();
      final suggested = find.byKey(const ValueKey('send-later-suggested'));
      expect(suggested, findsOneWidget);
      expect(tester.widget<ListTile>(suggested).selected, isTrue);
      final morning = DateTime.utc(2026, 11, 5, 16);
      final context = tester.element(suggested);
      expect(
        find.descendant(
          of: suggested,
          matching: find.text('Tomorrow 8:00 AM their time'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: suggested,
          matching: find.text(
            '8:00 AM for Maya '
            '(${SendLaterSheet.describe(context, morning)} for you)',
          ),
        ),
        findsOneWidget,
      );
      // Here, where the clock reads UTC: 4:00 PM for the user.
      if (DateTime.now().timeZoneOffset == Duration.zero) {
        expect(find.text('8:00 AM for Maya (4:00 PM for you)'), findsOneWidget);
      }

      await tester.tap(suggested);
      await tester.pumpAndSettle();
      expect((result! as ComposeSent).pending.scheduledFor, morning);
    });

    testWidgets('no time hint by day, nor without a consistent zone', (
      tester,
    ) async {
      SendLaterTimes.clock = () => _day;
      mailFrom(_maya);
      mailFrom(_sam, count: 2);
      await open(tester, to: const [_maya]);
      await hints(tester);
      expect(hint, findsNothing);
      SendLaterTimes.clock = () => _night;
      controller.to.remove(_maya);
      controller.to.add(_sam);
      await hints(tester);
      expect(hint, findsNothing);
      await finish(tester);
    });

    testWidgets('how quickly they reply, when no time hint applies', (
      tester,
    ) async {
      SendLaterTimes.clock = () => _day;
      mailFrom(_maya, replies: true);
      await open(tester, to: const [_maya]);
      await hints(tester);
      expect(find.text('Maya usually replies within 2 hours.'), findsOneWidget);
      expect(find.byKey(const ValueKey('writing-hint-action')), findsNothing);
      await finish(tester);
    });

    testWidgets('the time hint comes before the reply time', (tester) async {
      mailFrom(_maya, replies: true);
      await open(tester, to: const [_maya]);
      await hints(tester);
      expect(find.textContaining('11:40 PM for Maya'), findsOneWidget);
      expect(find.textContaining('usually replies'), findsNothing);
      await finish(tester);
    });

    testWidgets('fewer than 3 replies: no reply time', (tester) async {
      SendLaterTimes.clock = () => _day;
      mailFrom(_maya, count: 0);
      final asked = DateTime.utc(2026, 10, 21, 9);
      for (var i = 0; i < 2; i++) {
        app.store.messages.upsertSummaries(sent().id, [
          MessageSummary(
            uid: 300 + i,
            receivedAt: asked,
            messageId: 'few$i@citusmail.test',
            from: alice,
            to: const [_maya],
          ),
        ]);
        app.store.messages.upsertSummaries(inbox().id, [
          MessageSummary(
            uid: 300 + i,
            receivedAt: asked.add(const Duration(hours: 1)),
            inReplyTo: 'few$i@citusmail.test',
            messageId: 'fewr$i@example.com',
            from: _maya,
          ),
        ]);
      }
      await open(tester, to: const [_maya]);
      await hints(tester);
      expect(hint, findsNothing);
      await finish(tester);
    });

    testWidgets('did you mean: a near miss of a known address, swapped', (
      tester,
    ) async {
      mailFrom(_maya, replies: true);
      await open(tester);
      // Nothing while typing, only once the address is a chip.
      await type(tester, 'maya@exmaple.com');
      expect(hint, findsNothing);
      await type(tester, 'maya@exmaple.com,');
      expect(
        find.text(
          'You haven\'t written to maya@exmaple.com before. '
          'Did you mean maya@example.com?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Use maya@example.com'));
      await hints(tester);
      expect(controller.to.addresses.map((a) => a.address), [
        'maya@example.com',
      ]);
      // Then what there is to know about Maya.
      expect(find.textContaining('11:40 PM for Maya'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the near miss wins over the time hint', (tester) async {
      mailFrom(_maya);
      mailFrom(_sam);
      await open(tester, to: const [_maya]);
      await hints(tester);
      expect(find.textContaining('11:40 PM'), findsOneWidget);
      await type(tester, 'sam@studoi.example,');
      expect(
        find.textContaining('Did you mean sam@studio.example?'),
        (findsOneWidget),
      );
      await finish(tester);
    });

    testWidgets('no hint for new people, the user\'s own address or lists', (
      tester,
    ) async {
      mailFrom(_maya);
      mailFrom(_list, listId: 'dev.lists.example.org');
      await open(tester);
      await type(tester, 'priya@newco.example,');
      expect(hint, findsNothing);
      // The user's own address, and one a character off it.
      await type(tester, 'alice@citusmail.test,');
      await type(tester, 'alice@citusmail.tset,');
      expect(hint, findsNothing);
      controller.to
        ..remove(controller.to.addresses.first)
        ..remove(controller.to.addresses.first)
        ..remove(controller.to.addresses.first);
      // A list, though its mail is dated in one zone.
      await type(tester, 'dev@lists.example.org,');
      expect(hint, findsNothing);
      // With a list among the recipients there is no one local time.
      await type(tester, 'maya@example.com,');
      expect(hint, findsNothing);
      await finish(tester);
    });

    testWidgets('several recipients: the time hint only for one zone', (
      tester,
    ) async {
      mailFrom(_maya);
      mailFrom(_sam);
      mailFrom(_lee, hours: 1, replies: true);
      await open(tester, to: const [_maya, _sam, alice]);
      await hints(tester);
      // The user's own address doesn't count.
      expect(
        find.text('It\'s 11:40 PM for Maya and Sam. Send later?'),
        findsOneWidget,
      );
      controller.to.add(_lee);
      await hints(tester);
      // Lee is in another zone, so the reply time instead.
      expect(find.text('Lee usually replies within 2 hours.'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('close hides it for this message', (tester) async {
      mailFrom(_maya, replies: true);
      mailFrom(_sam);
      await open(tester, to: const [_maya]);
      await hints(tester);
      expect(hint, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('writing-hint-close')));
      await hints(tester);
      expect(hint, findsNothing);
      controller.to.add(_sam);
      await hints(tester);
      expect(hint, findsNothing);
      await finish(tester);
    });

    testWidgets('with the setting off, no hints at all', (tester) async {
      app.services.settings.writingHints = false;
      mailFrom(_maya, replies: true);
      await open(tester, to: const [_maya]);
      await type(tester, 'maya@exmaple.com,');
      expect(hint, findsNothing);
      await finish(tester);
    });

    for (final (name, size) in [
      ('360', const Size(360, 760)),
      ('390', const Size(390, 844)),
      ('412', const Size(412, 915)),
      ('desktop', const Size(1440, 900)),
    ]) {
      testWidgets('no overflow at $name, text scale 1.3', (tester) async {
        const long = MailAddress(
          displayName: 'Maya Lindqvist',
          localPart: 'maya.lindqvist',
          domain: 'example-studio.com',
        );
        mailFrom(long, replies: true);
        await open(tester, size: size, textScale: 1.3);
        await type(tester, 'maya.lindqvsit@example-studio.com,');
        expect(find.textContaining('Did you mean'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('writing-hint-action')));
        await hints(tester);
        expect(find.textContaining('11:40 PM for Maya'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('writing-hint-action')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('send-later-suggested')),
          (findsOneWidget),
        );
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(5, 5)); // closes the sheet
        await tester.pumpAndSettle();
        SendLaterTimes.clock = () => _day;
        controller.hints.refresh();
        await hints(tester);
        expect(find.textContaining('usually replies'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await finish(tester);
      });
    }
  });
}
