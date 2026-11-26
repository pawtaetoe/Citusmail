// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Snooze, follow-ups, coming back to the app and the wake timer on their
// own: their controllers without the mail screen.

import 'package:citusmail/src/features/inbox/state/new_since_away.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/controllers.dart';
import 'support/test_app.dart';

MailAddress _address(String a) =>
    MailAddress(localPart: a.split('@').first, domain: a.split('@').last);

void main() {
  late TestApp app;
  late Controllers c;
  setUp(() async {
    app = await TestApp.create();
    c = Controllers(app);
    c.store.messages.upsertSummaries(c.box('INBOX').id, [
      MessageSummary(
        uid: 30,
        receivedAt: DateTime.utc(2026, 10, 20, 8),
        subject: 'Draft contract',
        from: _address('maria@studio.example'),
        messageId: 'contract@studio.example',
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
    ]);
    c.store.messages.upsertSummaries(c.box('Sent').id, [
      MessageSummary(
        uid: 20,
        receivedAt: DateTime.utc(2026, 11, 1, 10),
        sentAt: DateTime.utc(2026, 11, 1, 10),
        subject: 'Quote for the kitchen',
        from: _address('alice@citusmail.test'),
        to: [_address('ana@buildright.example')],
        messageId: 'quote.kitchen@citusmail.test',
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
    ]);
    c.refresh();
  });
  tearDown(() {
    c.dispose();
    return app.dispose();
  });

  // Two days ahead, in whole seconds (as the store keeps it).
  final later = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().add(const Duration(days: 2)).millisecondsSinceEpoch ~/
        1000 *
        1000,
    isUtc: true,
  );

  group('SnoozeController', () {
    test('only inbox mail with a Message-ID can be snoozed', () {
      expect(c.snoozes.canSnooze(c.message('Draft contract')), isTrue);
      expect(c.snoozes.canSnooze(c.message('Lunch?')), isFalse);
      c.snoozes.snooze([c.message('Lunch?')], later, 'Snoozed');
      expect(c.lastNotice, 'This email can\'t be snoozed.');
    });

    test('snoozed mail leaves the inbox until Undo', () {
      final contract = c.message('Draft contract');
      c.snoozes.snooze([contract], later, 'Snoozed till later');
      expect(c.lastNotice, 'Snoozed till later');
      expect(c.list.visible.map((m) => m.id), isNot(contains(contract.id)));
      expect(c.snoozes.snoozedUntil(c.message('Draft contract')), later);
      expect(c.wakeTimer.isSet, isFalse, reason: 'set by wake and refresh');

      c.undoLast();
      expect(c.snoozes.snoozedUntil(c.message('Draft contract')), isNull);
      expect(c.list.visible.map((m) => m.id), contains(contract.id));
    });

    test('unsnoozed now, with Undo', () {
      c.snoozes.snooze([c.message('Draft contract')], later, 'Snoozed');
      c.snoozes.unsnooze([c.message('Draft contract')]);
      expect(c.lastNotice, 'Unsnoozed');
      expect(c.snoozes.snoozedUntil(c.message('Draft contract')), isNull);
      c.undoLast();
      expect(c.snoozes.snoozedUntil(c.message('Draft contract')), later);
    });

    test('waking brings back what is due, and sets the timer', () {
      c.snoozes.snooze([c.message('Draft contract')], later, 'Snoozed');
      final back = <BackFromSnooze>[];
      c.snoozes.onBackFromSnooze = back.add;

      c.snoozes.wake();
      expect(back, isEmpty, reason: 'not due yet');
      expect(c.wakeTimer.isSet, isTrue);

      c.snoozes.wake(later.add(const Duration(minutes: 1)));
      expect(back, hasLength(1));
      expect(c.message('Draft contract').flags.seen, isFalse);
    });
  });

  group('FollowUpController', () {
    test('only mail the user sent can remind', () {
      final f = c.followUpController;
      expect(f.canFollowUp(c.message('Quote for the kitchen')), isTrue);
      expect(f.canFollowUp(c.message('Draft contract')), isFalse);
      f.remindIfNoReply(c.message('Draft contract'), later, 'Set');
      expect(c.lastNotice, 'Only mail you sent can remind you.');
    });

    test('a reminder is set, ended and brought back with Undo', () {
      final f = c.followUpController;
      final quote = c.message('Quote for the kitchen');
      f.remindIfNoReply(quote, later, 'I\'ll remind you');
      expect(c.lastNotice, 'I\'ll remind you');
      final set = f.followUpFor(quote)!;
      expect(c.counts.counts.value.followUps, 1);

      f.endFollowUp(set);
      expect(c.lastNotice, 'Reminder cancelled');
      expect(f.followUpFor(quote), isNull);
      c.undoLast();
      expect(f.followUpFor(quote), isNotNull);
    });

    test('checking brings back those with no reply, and says so', () {
      final f = c.followUpController;
      var back = 0;
      f.onFollowUpsBack = () => back++;
      f.remindIfNoReply(c.message('Quote for the kitchen'), later, 'Set');
      f.check(later.add(const Duration(hours: 1)));
      expect(back, 1);
      expect(
        f.followUpFor(c.message('Quote for the kitchen'))!.returned,
        isTrue,
      );
    });
  });

  group('AwayController', () {
    test('"Done" puts the mail back in its sections, with Undo', () {
      c.list.away.window = AwayWindow(
        DateTime.utc(2026, 10, 20),
        DateTime.utc(2026, 10, 21),
      );
      c.list.refresh();
      expect(c.list.newSinceAway.messages, isNotEmpty);

      c.away.doneWithAway();
      expect(c.lastNotice, 'Back in their sections');
      expect(c.list.away.window, isNull);
      c.undoLast();
      expect(c.list.away.window, isNotNull);

      c.away.markAwayRead();
      expect(c.lastNotice, startsWith('Marked as read ('));
      expect(c.list.newSinceAway.messages.every((m) => m.flags.seen), isTrue);
    });

    test('nothing away: nothing to do', () {
      c.away.doneWithAway();
      c.away.markAwayRead();
      expect(c.notices, isEmpty);
    });

    test('coming back wakes what is due', () {
      c.snoozes.snooze(
        [c.message('Draft contract')],
        DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        'Snoozed',
      );
      final back = <BackFromSnooze>[];
      c.snoozes.onBackFromSnooze = back.add;
      c.away.onHide();
      c.away.onResume();
      expect(back, hasLength(1));
    });
  });

  group('WakeTimer', () {
    test('nothing due: no timer; something due: it fires', () async {
      c.wakeTimer.schedule();
      expect(c.wakeTimer.isSet, isFalse);
      c.store.snoozes.snooze('contract@studio.example', DateTime.now().toUtc());
      c.wakeTimer.schedule();
      expect(c.wakeTimer.isSet, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(c.wakes, 1, reason: 'at least a second later');
    });

    test('disposed: no timer', () {
      c.store.snoozes.snooze('contract@studio.example', later);
      c.wakeTimer.dispose();
      c.wakeTimer.schedule();
      expect(c.wakeTimer.isSet, isFalse);
    });
  });
}
