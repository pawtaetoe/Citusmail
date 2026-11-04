// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/services/app_settings.dart';
import 'package:citusmail/src/services/mail_notices.dart';
import 'package:citusmail/src/services/mail_notifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

/// Records what would be posted, instead of the system.
final class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add(_Shown(id, title, body, notificationDetails, payload));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Shown {
  _Shown(this.id, this.title, this.body, this.details, this.payload);
  final int id;
  final String? title;
  final String? body;
  final NotificationDetails? details;
  final String? payload;

  AndroidNotificationDetails get android => details!.android!;
}

final _account = Account(
  id: 3,
  email: 'alice@citusmail.test',
  username: 'alice@citusmail.test',
  imap: ServerSettings(
    host: 'mail.citusmail.test',
    port: 993,
    security: ConnectionSecurity.implicitTls,
  ),
  smtp: ServerSettings(
    host: 'mail.citusmail.test',
    port: 465,
    security: ConnectionSecurity.implicitTls,
  ),
  sortOrder: 0,
  createdAt: DateTime.utc(2026),
);

var _nextId = 100;

StoredMessage _message(
  String name,
  String address,
  String subject,
  String snippet, {
  String? code,
}) {
  final id = _nextId++;
  final at = address.split('@');
  return StoredMessage(
    id: id,
    mailboxId: 1,
    accountId: _account.id,
    uid: id,
    receivedAt: DateTime.utc(2026, 11, 4, 9, id % 60),
    size: 2048,
    flags: const MessageFlags(0),
    hasAttachments: false,
    category: MessageCategory.general,
    categorySource: CategorySource.rule,
    subject: subject,
    from: MailAddress(displayName: name, localPart: at[0], domain: at[1]),
    snippet: snippet,
    code: code ?? '',
  );
}

StoredMessage _bank() => _message(
  'Northwind Bank',
  'alerts@northwindbank.example',
  'Your one-time passcode',
  'Use 482913 to sign in to Online Banking. It expires in 10 minutes. '
      'Never share this code, not even with us.',
  code: '482913',
);

StoredMessage _dentist() => _message(
  'Riverside Dental',
  'hello@riversidedental.example',
  'Reminder: check-up on Thursday at 3:30 pm',
  'Hi Alice, this is a reminder of your appointment with Dr. Okafor on '
      'Thursday 6 November at 3:30 pm. Reply C to confirm or call us to '
      'change it.',
);

StoredMessage _mum() => _message(
  'Mum',
  'margaret.lee@example.com',
  'Sunday lunch',
  'Are you still coming on Sunday? Dad is making his lasagne, bring '
      'something sweet if you can.',
);

/// Five more, oldest first.
List<StoredMessage> _more() => [
  _message(
    'Priya Shah',
    'priya@example.org',
    'Holiday photos',
    'Here they are!',
  ),
  _message(
    'Tom Becker',
    'tom.becker@example.net',
    'Re: the bike',
    'Still for sale?',
  ),
  _message(
    'Greenleaf Library',
    'noreply@greenleaf.example',
    'Your hold is ready',
    'Pick up by 12 November.',
  ),
  _message(
    'Sam Ortiz',
    'sam@example.com',
    'Quick question',
    'Do you have a minute today?',
  ),
  _message('Jo', 'jo@example.com', 'Lunch?', 'Thai place at 1?'),
];

NewMail _mail(List<StoredMessage> messages, {int? total}) =>
    NewMail(_account.id, messages, total: total ?? messages.length);

void main() {
  group('MailNotices', () {
    test('one notification per message: sender, subject, preview', () {
      final dentist = _dentist();
      final mum = _mum();
      final notices = MailNotices.build(
        _account,
        _mail([dentist, mum]),
        layout: NoticeLayout.separate,
      );
      expect(notices, hasLength(2));
      final first = notices.first;
      expect(first.title, 'Riverside Dental');
      expect(first.body, 'Reminder: check-up on Thursday at 3:30 pm');
      expect(first.preview, startsWith('Hi Alice, this is a reminder'));
      expect(first.preview!.length, lessThanOrEqualTo(141));
      expect(first.preview, endsWith('…'));
      expect(first.payload, 'message:${dentist.id}');
      expect(first.code, isNull);
      expect(first.copyActionId, isNull);
      expect(notices.last.title, 'Mum');
      expect(
        notices.last.text,
        'Sunday lunch\nAre you still coming on Sunday? Dad is making his '
        'lasagne, bring something sweet if you can.',
      );
      expect(notices.last.payload, 'message:${mum.id}');
    });

    test('a code: in the title, with a Copy code button', () {
      final bank = _bank();
      final notice = MailNotices.build(
        _account,
        _mail([bank]),
        layout: NoticeLayout.grouped,
      ).single;
      expect(notice.title, 'Code 482913 from Northwind Bank');
      expect(notice.body, 'Your one-time passcode');
      expect(notice.code, '482913');
      expect(notice.copyActionId, 'copy:${bank.id}:482913');
    });

    test('desktop: the newest five, then "and N more"', () {
      final messages = [_mum(), _dentist(), ..._more()];
      final notices = MailNotices.build(
        _account,
        _mail(messages, total: 9),
        layout: NoticeLayout.separate,
      );
      expect(notices, hasLength(6));
      expect(notices.take(5).map((n) => n.title), [
        'Priya Shah',
        'Tom Becker',
        'Greenleaf Library',
        'Sam Ortiz',
        'Jo',
      ]);
      final more = notices.last;
      expect(more.isSummary, isTrue);
      expect(more.title, 'And 4 more new emails');
      expect(more.body, 'Riverside Dental, Mum · alice@citusmail.test');
      expect(more.payload, isNull);
      expect(more.id, MailNotices.summaryId(_account.id));
    });

    test('desktop: five or fewer, no "more"', () {
      final notices = MailNotices.build(
        _account,
        _mail(_more()),
        layout: NoticeLayout.separate,
      );
      expect(notices, hasLength(5));
      expect(notices.any((n) => n.isSummary), isFalse);
    });

    test('Android: every message, and a summary listing them', () {
      final messages = [_bank(), _dentist(), ..._more()];
      final notices = MailNotices.build(
        _account,
        _mail(messages, total: 12),
        layout: NoticeLayout.grouped,
      );
      expect(notices, hasLength(8));
      final summary = notices.last;
      expect(summary.isSummary, isTrue);
      expect(summary.title, '12 new emails');
      expect(summary.body, 'Jo, Sam Ortiz, Greenleaf Library, …');
      expect(summary.lines, hasLength(MailNotices.summaryLines));
      expect(summary.lines.first, 'Jo — Lunch?');
      expect(
        summary.lines.last,
        'Riverside Dental — Reminder: check-up on Thursday at 3:30 pm',
      );
      expect(summary.more, 'and 6 more');
    });

    test('Android: one message, no summary', () {
      final notices = MailNotices.build(
        _account,
        _mail([_mum()]),
        layout: NoticeLayout.grouped,
      );
      expect(notices.single.title, 'Mum');
    });

    test('previews off: sender and subject only; codes keep the button', () {
      final bank = _bank();
      final notices = MailNotices.build(
        _account,
        _mail([bank, _dentist()]),
        layout: NoticeLayout.separate,
        previews: false,
      );
      expect(notices.map((n) => n.preview), [null, null]);
      expect(notices.last.text, 'Reminder: check-up on Thursday at 3:30 pm');
      expect(notices.first.title, 'Code 482913 from Northwind Bank');
      expect(notices.first.copyActionId, 'copy:${bank.id}:482913');
    });

    test('app lock on: only "New mail", nothing from the messages', () {
      for (final layout in NoticeLayout.values) {
        final one = MailNotices.build(
          _account,
          _mail([_bank()]),
          layout: layout,
          hideContent: true,
        ).single;
        expect(one.title, 'New mail');
        expect(one.body, 'Unlock Citusmail to read it.');
        expect(one.preview, isNull);
        expect(one.code, isNull);
        expect(one.copyActionId, isNull);
        expect(one.payload, isNull);
        expect(one.lines, isEmpty);

        final many = MailNotices.build(
          _account,
          _mail([_bank(), _dentist(), _mum()], total: 7),
          layout: layout,
          hideContent: true,
        ).single;
        expect(many.title, '7 new emails');
        expect(many.body, 'Unlock Citusmail to read them.');
        expect(many.lines, isEmpty);
      }
    });

    test('no sender name, no subject, no preview', () {
      final bare = StoredMessage(
        id: 7,
        mailboxId: 1,
        accountId: _account.id,
        uid: 7,
        receivedAt: DateTime.utc(2026, 11, 4),
        size: 100,
        flags: const MessageFlags(0),
        hasAttachments: false,
        category: MessageCategory.general,
        categorySource: CategorySource.rule,
        from: const MailAddress(localPart: 'info', domain: 'shop.example'),
        snippet: '  \n ',
      );
      final notice = MailNotices.build(
        _account,
        _mail([bare]),
        layout: NoticeLayout.separate,
      ).single;
      expect(notice.title, 'info@shop.example');
      expect(notice.body, '(no subject)');
      expect(notice.preview, isNull);
    });

    test('notification ids stay clear of reminders and summaries', () {
      expect(MailNotices.idFor(0x7FFFFFFF), lessThan(0x20000000));
      expect(MailNotices.summaryId(3), greaterThanOrEqualTo(0x40000000));
      expect(MailNotices.messageIdOf('message:42'), 42);
      expect(MailNotices.messageIdOf('copy:42:123456'), isNull);
    });
  });

  group('Copy code', () {
    test('parses only its own action ids', () {
      expect(CopyCodeAction.parse('copy:42:482913'), (
        messageId: 42,
        code: '482913',
      ));
      expect(CopyCodeAction.parse('copy:42:X7K-Q2P'), (
        messageId: 42,
        code: 'X7K-Q2P',
      ));
      expect(CopyCodeAction.parse('message:42'), isNull);
      expect(CopyCodeAction.parse('copy:42:'), isNull);
      expect(CopyCodeAction.parse('copy::123'), isNull);
      expect(CopyCodeAction.parse('copy:abc:123'), isNull);
      expect(CopyCodeAction.parse(null), isNull);
    });

    test('copies the code and dismisses that message only', () async {
      final copied = <String>[];
      final dismissed = <int>[];
      final handled = await CopyCodeAction.handle(
        'copy:4242:482913',
        'message:4242',
        copy: (code) async => copied.add(code),
        dismiss: (id) async => dismissed.add(id),
      );
      expect(handled, isTrue);
      expect(copied, ['482913']);
      expect(dismissed, [MailNotices.idFor(4242)]);
    });

    test('Windows: the action comes back as the payload', () async {
      final copied = <String>[];
      final handled = await CopyCodeAction.handle(
        'copy:7:551204',
        'copy:7:551204',
        copy: (code) async => copied.add(code),
      );
      expect(handled, isTrue);
      expect(copied, ['551204']);
    });

    test('a tap on the notification is not a copy', () async {
      final copied = <String>[];
      final handled = await CopyCodeAction.handle(
        null,
        'message:42',
        copy: (code) async => copied.add(code),
      );
      expect(handled, isFalse);
      expect(copied, isEmpty);
    });

    testWidgets('Android background handler: puts the code on the clipboard', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      const channel = MethodChannel('citusmail/background-clipboard');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      try {
        await copyCodeInBackground(
          const NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            id: 4242,
            actionId: 'copy:4242:482913',
            payload: 'message:4242',
          ),
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
      expect(calls.single.method, 'copy');
      final args = calls.single.arguments as Map;
      expect(args['text'], '482913');
      expect(args['sensitive'], isTrue);
      expect(args['confirmation'], 'Code copied');
    });
  });

  group('MailNotifier', () {
    test('Android: bundled, with BigText previews and a quiet Copy code', () {
      final plugin = _FakePlugin();
      final notifier = MailNotifier.forTesting(plugin, NoticeLayout.grouped);
      final bank = _bank();
      final dentist = _dentist();
      return notifier.show(_account, _mail([bank, dentist])).then((_) {
        expect(plugin.shown, hasLength(3));
        final code = plugin.shown[0];
        expect(code.id, MailNotices.idFor(bank.id));
        expect(code.title, 'Code 482913 from Northwind Bank');
        expect(code.body, 'Your one-time passcode');
        expect(code.payload, 'message:${bank.id}');
        expect(code.android.groupKey, 'account.3');
        expect(code.android.setAsGroupSummary, isFalse);
        expect(code.android.groupAlertBehavior, GroupAlertBehavior.summary);
        expect(code.android.visibility, NotificationVisibility.private);
        final action = code.android.actions!.single;
        expect(action.id, 'copy:${bank.id}:482913');
        expect(action.title, 'Copy code');
        expect(action.showsUserInterface, isFalse);
        expect(action.cancelNotification, isTrue);
        final big = code.android.styleInformation! as BigTextStyleInformation;
        expect(big.bigText, startsWith('Your one-time passcode\nUse 482913'));
        expect(code.details!.linux!.actions.single.key, action.id);
        expect(code.details!.windows!.actions.single.arguments, action.id);

        expect(plugin.shown[1].android.actions, isEmpty);

        final summary = plugin.shown[2];
        expect(summary.title, '2 new emails');
        expect(summary.payload, isNull);
        expect(summary.android.setAsGroupSummary, isTrue);
        expect(summary.android.groupAlertBehavior, GroupAlertBehavior.all);
        expect(summary.android.visibility, NotificationVisibility.private);
        final inbox =
            summary.android.styleInformation! as InboxStyleInformation;
        expect(inbox.lines, [
          'Riverside Dental — Reminder: check-up on Thursday at 3:30 pm',
          'Northwind Bank — Code 482913',
        ]);
      });
    });

    test('desktop: subject and preview in the body', () async {
      final plugin = _FakePlugin();
      final notifier = MailNotifier.forTesting(plugin, NoticeLayout.separate);
      await notifier.show(_account, _mail([_mum()]));
      expect(
        plugin.shown.single.body,
        'Sunday lunch\nAre you still coming on Sunday? Dad is making his '
        'lasagne, bring something sweet if you can.',
      );
    });

    test('announce: honours the previews setting and the app lock', () async {
      final app = await TestApp.create();
      addTearDown(app.dispose);
      final plugin = _FakePlugin();
      final notifier = MailNotifier.forTesting(plugin, NoticeLayout.grouped);

      AppSettings(app.store).notificationPreviews = false;
      await notifier.announce(app.store, _account, _mail([_bank()]));
      final quiet = plugin.shown.single;
      expect(quiet.body, 'Your one-time passcode');
      expect(quiet.android.styleInformation, isNull);
      expect(quiet.android.actions, hasLength(1));

      plugin.shown.clear();
      app.store.settings.write('lock.enabled', 'on');
      await notifier.announce(app.store, _account, _mail([_bank(), _mum()]));
      final locked = plugin.shown.single;
      expect(locked.title, '2 new emails');
      expect(locked.body, 'Unlock Citusmail to read them.');
      expect(locked.android.actions, isEmpty);
      expect(locked.android.styleInformation, isNull);
    });
  });

  test('previews are on by default', () async {
    final app = await TestApp.create();
    addTearDown(app.dispose);
    expect(AppSettings(app.store).notificationPreviews, isTrue);
  });
}
