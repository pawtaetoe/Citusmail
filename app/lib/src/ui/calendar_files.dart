// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mail_view/mail_view.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'attachment_saver.dart';

/// Hands an event to the user's own calendar app, the app having no
/// calendar of its own: the .ics file is written to the app's temporary
/// folder and opened with the system (on Android, a "view" request for
/// a text/calendar file, which calendar apps answer). Nothing is sent
/// anywhere.
abstract final class CalendarFiles {
  static const _android = MethodChannel('citusmail/files');

  /// Whether this platform can hand a file to another app at all.
  static bool get canOpen =>
      Platform.isAndroid ||
      Platform.isLinux ||
      Platform.isWindows ||
      Platform.isMacOS;

  /// Opens [invite] in the calendar app. False if nothing took it.
  static Future<bool> open(CalendarInvite invite) async {
    final bytes = Uint8List.fromList(utf8.encode(invite.text));
    final name = fileName(invite);
    try {
      if (Platform.isAndroid) {
        return await _android.invokeMethod<bool>('openCalendar', {
              'name': name,
              'bytes': bytes,
            }) ??
            false;
      }
      if (!canOpen) return false;
      final directory = Directory(
        '${(await getTemporaryDirectory()).path}'
        '${Platform.pathSeparator}citusmail-events',
      );
      // Only the latest event is kept there.
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      directory.createSync(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      return await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  /// Saves the .ics file to Downloads (never overwriting one).
  static Future<File> save(CalendarInvite invite) =>
      AttachmentSaver.saveBytes(fileName(invite), utf8.encode(invite.text));

  /// "Q4 roadmap review.ics", safe for any file system.
  static String fileName(CalendarInvite invite) {
    final name = SafeFileName.from(
      '${invite.summary ?? 'event'}.ics',
      fallback: 'event.ics',
    );
    return name.toLowerCase().endsWith('.ics') ? name : '$name.ics';
  }
}
