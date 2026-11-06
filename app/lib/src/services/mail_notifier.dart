// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:background_clipboard/background_clipboard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../mail/follow_up_times.dart';
import '../security/app_lock.dart';
import 'app_settings.dart';
import 'mail_notices.dart';
import 'reminders.dart';

/// Shows new-mail notifications through the system: one per message with
/// the sender, the subject and a short preview, and a Copy code button for
/// verification codes. On Android they are bundled per account under a
/// summary, and the lock screen shows only that there is new mail; with
/// the app lock on, nothing but that there is new mail is shown anywhere.
final class MailNotifier {
  MailNotifier._(this._plugin, this._layout);

  /// A notifier posting to [plugin] (a fake in tests).
  @visibleForTesting
  MailNotifier.forTesting(this._plugin, this._layout);

  final FlutterLocalNotificationsPlugin _plugin;
  final NoticeLayout _layout;

  static const _channelId = 'new_mail';
  static const _appName = appName;

  /// Fixed ids identifying the app to Windows (not secret).
  static const _windowsAppId = 'Fluminaris.Citusmail.Mail';
  static const _windowsGuid = 'f3792bc8-af63-47a7-914b-a8425569fc47';

  /// Starts the notification system. [onOpen] gets the stored message id
  /// when a notification is tapped while the app runs.
  static Future<MailNotifier?> create({
    void Function(int messageId)? onOpen,
  }) async {
    if (!(Platform.isAndroid || Platform.isLinux || Platform.isWindows)) {
      return null;
    }
    final plugin = FlutterLocalNotificationsPlugin();
    try {
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification'),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: WindowsInitializationSettings(
            appName: _appName,
            appUserModelId: _windowsAppId,
            guid: _windowsGuid,
          ),
        ),
        onDidReceiveNotificationResponse: (response) async {
          // Linux and Windows: buttons arrive here, in the running app.
          try {
            final copied = await CopyCodeAction.handle(
              response.actionId,
              response.payload,
              copy: _copy,
              dismiss: (id) => plugin.cancel(id: id),
            );
            if (copied) return;
          } on Object catch (e) {
            debugPrint('copy code: ${e.runtimeType}');
            return;
          }
          final id = MailNotices.messageIdOf(response.payload);
          if (id != null) onOpen?.call(id);
        },
        // Android: Copy code runs in a background engine, without opening
        // the app.
        onDidReceiveBackgroundNotificationResponse: copyCodeInBackground,
      );
    } on Object catch (e) {
      // No notification service (e.g. a minimal Linux desktop): mail still
      // works, just without notifications.
      debugPrint('notifications unavailable: ${e.runtimeType}');
      return null;
    }
    return MailNotifier._(
      plugin,
      Platform.isAndroid ? NoticeLayout.grouped : NoticeLayout.separate,
    );
  }

  /// Asks for permission where the system requires it (Android 13+).
  Future<bool> requestPermission() async =>
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      true;

  /// Announces [mail] of [account] as the settings in [store] say: with
  /// previews or not, and only "New mail" while the app lock is on.
  Future<void> announce(MailStore store, Account account, NewMail mail) => show(
    account,
    mail,
    hideContent: AppLock.isEnabledIn(store),
    previews: AppSettings(store).notificationPreviews,
  );

  /// Announces [mail] of [account] (see [MailNotices.build]). With
  /// [hideContent] (the app lock is on), only that there is new mail.
  Future<void> show(
    Account account,
    NewMail mail, {
    bool hideContent = false,
    bool previews = true,
  }) async {
    final notices = MailNotices.build(
      account,
      mail,
      layout: _layout,
      hideContent: hideContent,
      previews: previews,
    );
    final summarized = notices.any((n) => n.isSummary);
    for (final notice in notices) {
      await _plugin.show(
        id: notice.id,
        title: notice.title,
        body: _layout == NoticeLayout.grouped ? notice.body : notice.text,
        notificationDetails: detailsFor(
          account,
          notice,
          bundled: summarized && !notice.isSummary,
        ),
        payload: notice.payload,
      );
    }
  }

  /// Announces snoozed mail that came back, one notification each, as
  /// the settings in [store] say (previews, the app lock).
  Future<void> announceBackFromSnooze(
    MailStore store,
    BackFromSnooze back,
  ) async {
    final hide = AppLock.isEnabledIn(store);
    final previews = AppSettings(store).notificationPreviews;
    for (final woken in back.messages) {
      final account = store.accounts.byId(woken.message.accountId);
      if (account == null) continue;
      final notice = MailNotices.backFromSnooze(
        woken.message,
        hideContent: hide,
        previews: previews,
      );
      await _plugin.show(
        id: notice.id,
        title: notice.title,
        body: _layout == NoticeLayout.grouped ? notice.body : notice.text,
        notificationDetails: detailsFor(account, notice),
        payload: notice.payload,
      );
    }
  }

  /// Posts reminders (a bill due, a free trial ending, a renewal) on a
  /// channel of their own, apart from new mail; tapping one opens its
  /// email. With [hideContent] (the app lock is on), only that there are
  /// reminders.
  Future<void> showReminders(
    List<ReminderNotice> notices, {
    bool hideContent = false,
  }) async {
    if (notices.isEmpty) return;
    if (hideContent) {
      await _plugin.show(
        id: _reminderSummaryId,
        title: notices.length == 1
            ? 'A reminder'
            : '${notices.length} reminders',
        body: 'Unlock $_appName to see ${notices.length == 1 ? 'it' : 'them'}.',
        notificationDetails: _reminderDetails,
      );
      return;
    }
    for (final n in notices) {
      await _plugin.show(
        id: n.id,
        title: n.title,
        body: n.text,
        notificationDetails: _reminderDetails,
        payload: 'message:${n.reminder.messageId}',
      );
    }
  }

  static const _reminderSummaryId = 0x2FFFFFFF;

  /// Tells the user, quietly and once, about each message scheduled with
  /// "Send later" that could not be sent (it waits in the Outbox, with
  /// Try again). With the app lock on, only that one was not sent.
  Future<void> announceFailedSends(MailStore store) async {
    final List<ScheduledSend> failed;
    try {
      failed = ScheduledSends(store, Sender(store)).claimFailures();
    } on Object catch (e) {
      debugPrint('send later: ${e.runtimeType}');
      return;
    }
    final hide = AppLock.isEnabledIn(store);
    for (final s in failed) {
      final data = s.entry.data;
      final subject = data == null
          ? null
          : const MimeParser().parse(data).subject?.trim();
      await _plugin.show(
        id: _failedSendBase | (s.entry.id & 0x0FFFFFFF),
        title: 'A scheduled email wasn\'t sent',
        body: hide
            ? 'Unlock $_appName to see it in the Outbox.'
            : '“${subject == null || subject.isEmpty ? '(no subject)' : subject}” '
                  'is in your Outbox. Open it to try again.',
        notificationDetails: _failedSendDetails,
      );
    }
  }

  /// Notification ids of failed scheduled sends, apart from mail's.
  static const _failedSendBase = 0x30000000;

  static const _failedSendDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'send_failures',
      'Scheduled emails not sent',
      channelDescription:
          'A message scheduled with Send later could not be sent',
      // Quiet: no sound, no pop-up.
      importance: Importance.low,
      priority: Priority.low,
      category: AndroidNotificationCategory.error,
      visibility: NotificationVisibility.private,
    ),
  );

  /// Tells the user about sent mail back with "No reply yet" ("No reply
  /// from Ana to “Quote for the kitchen” — sent 3 days ago"), once each,
  /// on a channel of its own. Like bill reminders, only in the daytime:
  /// at night they wait for the morning. None with notifications or
  /// follow-up notifications off, nor while [inFront] (the inbox shows
  /// them); those are not posted later either. With the app lock on, only
  /// that an email is waiting for a reply.
  Future<void> announceFollowUps(
    MailStore store, {
    bool inFront = false,
    DateTime? now,
  }) async {
    final List<MailNotice> notices;
    try {
      notices = followUpNotices(store, inFront: inFront, now: now);
    } on Object catch (e) {
      debugPrint('follow-ups: ${e.runtimeType}');
      return;
    }
    for (final n in notices) {
      await _plugin.show(
        id: n.id,
        title: n.title,
        body: n.body,
        notificationDetails: _followUpDetails,
        payload: n.payload,
      );
    }
  }

  /// The follow-up notifications to post now (see [announceFollowUps]);
  /// each returned follow-up is claimed once, whether posted or not,
  /// except at night, when they wait.
  @visibleForTesting
  static List<MailNotice> followUpNotices(
    MailStore store, {
    bool inFront = false,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final settings = AppSettings(store);
    final followUps = FollowUpReminders(store);
    final post = settings.notifications && settings.followUpNotifications;
    if (post &&
        (at.hour < ReminderCheck.fromHour ||
            at.hour > ReminderCheck.untilHour)) {
      return const []; // in the morning
    }
    final claimed = followUps.claimUnnotified();
    if (!post || inFront) return const [];
    final hide = AppLock.isEnabledIn(store);
    return [
      for (final f in claimed)
        hide
            ? MailNotice(
                id: followUpId(f.messageId),
                title: 'An email is waiting for a reply',
                body: 'Unlock $_appName to see it.',
              )
            : MailNotice(
                id: followUpId(f.messageId),
                title: 'No reply yet',
                body: FollowUpWords.notification(f, at),
                messageId: followUps.sentCopy(f)?.id,
              ),
    ];
  }

  /// A notification id of its own for each follow-up, stable across runs,
  /// apart from new mail, reminders (0x20000000) and failed sends
  /// (0x30000000): 0x40000000 to 0x4FFFFFFF.
  static int followUpId(String messageId) {
    var hash = 0x811C9DC5;
    for (final unit in messageId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return 0x40000000 | (hash & 0x0FFFFFFF);
  }

  static const _followUpDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'follow_ups',
      'Follow-up reminders',
      channelDescription:
          'An email you sent got no reply by the time you chose',
      category: AndroidNotificationCategory.reminder,
      // The lock screen shows only that there is a notification.
      visibility: NotificationVisibility.private,
      groupKey: 'follow_ups',
    ),
  );

  /// Checks for reminders to post after a sync ([ReminderCheck] decides
  /// whether it is time), honouring the app lock.
  Future<void> remind(MailStore store) async {
    try {
      await ReminderCheck.run(
        store,
        (notices) =>
            showReminders(notices, hideContent: AppLock.isEnabledIn(store)),
      );
    } on Object catch (e) {
      debugPrint('reminders: ${e.runtimeType}');
    }
  }

  static const _reminderDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Bill and trial reminders',
      channelDescription:
          'Bills due, free trials ending, subscriptions renewing and '
          'appointments tomorrow',
      category: AndroidNotificationCategory.reminder,
      // The lock screen shows only that there is a notification.
      visibility: NotificationVisibility.private,
      groupKey: 'reminders',
    ),
  );

  /// How [notice] looks on each system. When [bundled], its summary makes
  /// the sound (Android), not each message.
  @visibleForTesting
  static NotificationDetails detailsFor(
    Account account,
    MailNotice notice, {
    bool bundled = false,
  }) {
    final copyAction = notice.copyActionId;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'New mail',
        channelDescription: 'Sender, subject and a short preview of new mail',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.email,
        // The lock screen shows only that there is new mail ("Contents
        // hidden"); the details show once the phone is unlocked.
        visibility: NotificationVisibility.private,
        groupKey: 'account.${account.id}',
        setAsGroupSummary: notice.isSummary && notice.lines.isNotEmpty,
        groupAlertBehavior: bundled
            ? GroupAlertBehavior.summary
            : GroupAlertBehavior.all,
        subText: account.email,
        when: notice.receivedAt?.millisecondsSinceEpoch,
        showWhen: notice.receivedAt != null,
        styleInformation: notice.lines.isNotEmpty
            ? InboxStyleInformation(
                notice.lines,
                contentTitle: notice.title,
                summaryText: notice.more,
              )
            : notice.preview != null
            ? BigTextStyleInformation(notice.text, contentTitle: notice.title)
            : null,
        actions: [
          if (copyAction != null)
            AndroidNotificationAction(
              copyAction,
              CopyCodeAction.label,
              // Copies in the background: the app does not open.
              showsUserInterface: false,
              cancelNotification: true,
            ),
        ],
      ),
      linux: LinuxNotificationDetails(
        category: LinuxNotificationCategory.emailArrived,
        actions: [
          if (copyAction != null)
            LinuxNotificationAction(
              key: copyAction,
              label: CopyCodeAction.label,
            ),
        ],
      ),
      windows: WindowsNotificationDetails(
        timestamp: notice.receivedAt,
        actions: [
          if (copyAction != null)
            WindowsAction(content: CopyCodeAction.label, arguments: copyAction),
        ],
      ),
    );
  }

  static Future<void> _copy(String code) => BackgroundClipboard.copy(
    code,
    label: 'Verification code',
    sensitive: true,
    confirmation: 'Code copied',
  );
}

/// Android: a Copy code button pressed (in a background engine Android
/// starts for it, also while the app is closed). Copies the code; the
/// plugin has already removed the notification. Nothing else changes.
@pragma('vm:entry-point')
Future<void> copyCodeInBackground(NotificationResponse response) async {
  try {
    await CopyCodeAction.handle(
      response.actionId,
      response.payload,
      copy: MailNotifier._copy,
    );
  } on Object catch (e) {
    debugPrint('copy code: ${e.runtimeType}');
  }
}
