// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The outbox and send later, invitations and the accounts' order on
// their own: their controllers without the mail screen.

import 'package:citusmail/src/features/accounts/state/account_order.dart';
import 'package:citusmail/src/features/compose/state/outbox_controller.dart';
import 'package:citusmail/src/features/compose/state/send_later_times.dart';
import 'package:citusmail/src/features/reader/state/invitation_controller.dart';
import 'package:citusmail/src/features/reader/state/reader_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'support/controllers.dart';
import 'support/test_app.dart';

/// Wednesday 4 November 2026, 9:10 in the morning.
final _now = DateTime(2026, 11, 4, 9, 10);
final _thursday8 = DateTime(2026, 11, 5, 8);

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

  group('OutboxController', () {
    late OutboxController outbox;
    setUp(() {
      SendLaterTimes.clock = () => _now;
      outbox = OutboxController(
        app.services,
        c.followUps,
        c.compose,
        refresh: c.refresh,
        notify: c.notify,
      );
    });
    tearDown(() => SendLaterTimes.clock = DateTime.now);

    ScheduledSend scheduleOne() {
      app.services.sender.schedule(
        Draft(
          accountId: c.accountId,
          to: [const MailAddress(localPart: 'bob', domain: 'x.example')],
          subject: 'Quarterly numbers',
          body: 'Here they are, as promised.',
        ),
        _thursday8,
        now: _now,
      );
      return outbox.scheduledSends.all().single;
    }

    test('scheduled mail waits in the outbox', () {
      final s = scheduleOne();
      expect(outbox.outbox, hasLength(1));
      expect(s.at.toLocal(), _thursday8);
    });

    test('another time: it waits for that, and says so', () {
      final s = scheduleOne();
      final friday = DateTime(2026, 11, 6, 8);
      outbox.rescheduleSend(s, friday, 'Sends Friday morning');
      expect(c.lastNotice, 'Sends Friday morning');
      expect(outbox.scheduledSends.all().single.at.toLocal(), friday);
    });

    test('keep writing: it goes back to the compose window', () {
      final s = scheduleOne();
      outbox.editScheduled(s);
      expect(c.drafts.single.subject, 'Quarterly numbers');
      expect(outbox.scheduledSends.all(), isEmpty);
    });

    test('don\'t send: kept as a draft', () {
      final s = scheduleOne();
      outbox.cancelScheduled(s);
      expect(c.lastNotice, startsWith('It won\'t be sent.'));
      expect(outbox.scheduledSends.all(), isEmpty);
    });

    test('send now, and Undo puts it back at its time', () {
      final s = scheduleOne();
      outbox.sendScheduledNow(s);
      expect(c.lastNotice, 'Sending…');
      expect(outbox.scheduledSends.all(), isEmpty);
      c.undoLast();
      expect(outbox.scheduledSends.all().single.at.toLocal(), _thursday8);
    });
  });

  group('InvitationController', () {
    late InvitationController invitations;
    setUp(() {
      invitations = InvitationController(
        app.services,
        refresh: c.refresh,
        notify: c.notify,
      );
    });
    tearDown(() => invitations.dispose());

    Future<ReaderReady> openInvite() async {
      final message = app.seedFixture(
        '../invites/outlook-teams-request.eml',
        subject: 'Q4 roadmap review',
        uid: 70,
        receivedAt: DateTime.now().toUtc(),
      );
      return c.reader.readerFor(message);
    }

    test('accepting tells the organizer, with Undo', () async {
      final r = await openInvite();
      final invite = r.view.invite!;
      expect(
        invitations.ownAttendee(r.message, invite)?.email,
        'alice@citusmail.test',
      );
      var changes = 0;
      invitations.changed.addListener(() => changes++);

      expect(invitations.answer(r, CalendarAnswer.accepted), isNull);
      expect(c.lastNotice, 'Accepted. Telling Ana Lima…');
      expect(invitations.answers.of(invite), CalendarAnswer.accepted);
      final queued = app.store.outbox.sends().single;
      expect((queued.action as SendAction).recipients, [
        'ana.lima@contoso.example',
      ]);
      expect(changes, 1);

      c.undoLast();
      expect(app.store.outbox.sends(), isEmpty);
      expect(invitations.answers.of(invite), isNull);
      expect(changes, 2);
    });

    test('a message that isn\'t an invitation can\'t be answered', () async {
      final r = await c.reader.readerFor(c.message('Hello there'));
      expect(
        invitations.answer(r, CalendarAnswer.accepted),
        'This invitation can\'t be answered.',
      );
    });
  });

  group('AccountOrder', () {
    test('reordering notifies', () {
      final order = AccountOrder(app.store);
      addTearDown(order.dispose);
      var changes = 0;
      order.changed.addListener(() => changes++);
      order.reorder([c.accountId]);
      expect(changes, 1);
      expect(app.store.accounts.all().single.id, c.accountId);
    });
  });
}
