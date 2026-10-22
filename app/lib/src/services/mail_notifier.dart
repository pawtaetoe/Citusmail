// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// Shows new-mail notifications through the system: the sender and the
/// subject, never the text. On Android the lock screen shows only that
/// there is new mail.
final class MailNotifier {
  MailNotifier._(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  static const _channelId = 'new_mail';
  static const _appName = 'Fmail';

  /// Fixed ids identifying the app to Windows (not secret).
  static const _windowsAppId = 'Fmail.Fmail.Mail';
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
        onDidReceiveNotificationResponse: (response) {
          final id = _messageId(response.payload);
          if (id != null) onOpen?.call(id);
        },
      );
    } on Object catch (e) {
      // No notification service (e.g. a minimal Linux desktop): mail still
      // works, just without notifications.
      debugPrint('notifications unavailable: ${e.runtimeType}');
      return null;
    }
    return MailNotifier._(plugin);
  }

  /// Asks for permission where the system requires it (Android 13+).
  Future<bool> requestPermission() async =>
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      true;

  /// Announces [mail] of [account]: one notification per message, or one
  /// summary when many arrive at once.
  Future<void> show(Account account, NewMail mail) async {
    if (mail.isEmpty) return;
    if (mail.total > 3) {
      await _plugin.show(
        id: _summaryId(account.id),
        title: '${mail.total} new messages',
        body: account.email,
        notificationDetails: _details(account),
      );
      return;
    }
    for (final message in mail.messages) {
      final from = message.from;
      final sender = from?.displayName?.trim().isNotEmpty == true
          ? from!.displayName!
          : from?.address ?? 'New mail';
      final subject = message.subject?.trim();
      await _plugin.show(
        id: message.id & 0x7FFFFFFF,
        title: sender,
        body: subject == null || subject.isEmpty ? '(no subject)' : subject,
        notificationDetails: _details(account),
        payload: 'message:${message.id}',
      );
    }
  }

  static NotificationDetails _details(Account account) => NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'New mail',
      channelDescription: 'Sender and subject of new mail',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.email,
      // The lock screen shows only that there is new mail.
      visibility: NotificationVisibility.private,
      groupKey: 'account.${account.id}',
      subText: account.email,
    ),
    linux: const LinuxNotificationDetails(
      category: LinuxNotificationCategory.emailArrived,
    ),
  );

  static int _summaryId(int accountId) => 0x40000000 | (accountId & 0xFFFFFF);

  static int? _messageId(String? payload) {
    if (payload == null || !payload.startsWith('message:')) return null;
    return int.tryParse(payload.substring('message:'.length));
  }
}
