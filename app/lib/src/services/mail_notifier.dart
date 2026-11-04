// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:background_clipboard/background_clipboard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
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
          'Bills due, free trials ending and subscriptions renewing',
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
