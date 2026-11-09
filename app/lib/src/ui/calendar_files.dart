// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mail_view/mail_view.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'attachment_saver.dart';

/// Hands an event to the user's own calendar app, the app having no
/// calendar of its own: the .ics file is written to a folder of the app's
/// own data (on Android, its private cache, offered through a
/// FileProvider) and opened with the system (on Android, a "view" request
/// for a text/calendar file, which calendar apps answer). Nothing is sent
/// anywhere. The file is removed once the calendar app has had time to
/// read it.
abstract final class CalendarFiles {
  static const _android = MethodChannel('citusmail/files');

  /// Where the file is written on desktops: the app's own data folder,
  /// which the store keeps readable by the user only (mode 700 on Linux
  /// and macOS; private under the profile on Windows), never the shared
  /// temporary folder, where everyone on the machine could read who is
  /// meeting whom. Tests point it elsewhere.
  static Future<Directory> Function() dataDirectory =
      getApplicationSupportDirectory;

  /// Opens a file with the system; tests replace it.
  static Future<bool> Function(Uri file) launcher = (uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// How long the file is kept for the calendar app to read it (the
  /// system starts the app and hands it the path; the app reads the file
  /// as it comes up) before it is deleted.
  static Duration keepFor = const Duration(minutes: 2);

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
        '${(await dataDirectory()).path}${Platform.pathSeparator}events',
      );
      // Only the latest event is ever there.
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      directory.createSync(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes, flush: true);
      final launched = await launcher(Uri.file(file.path));
      if (launched) {
        unawaited(Future<void>.delayed(keepFor, () => _remove(directory)));
      } else {
        _remove(directory);
      }
      return launched;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  static void _remove(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Gone already, or still open elsewhere: the next hand-off clears it.
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
