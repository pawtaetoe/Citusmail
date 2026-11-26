// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mail_pairing/mail_pairing.dart';

/// Hands the sealed accounts file to an app the user picks in Android's
/// share sheet (Quick Share, a messenger, a USB cable's Files app...).
/// The file is written to the app's private cache, offered through its
/// FileProvider for that one file only, and deleted once the computer's
/// code has expired anyway.
abstract final class PairingShare {
  static const _android = MethodChannel('citusmail/files');

  /// Shares [bytes]; false if no app could take it. Tests replace it.
  static Future<bool> Function(Uint8List bytes) share = _share;

  static Future<bool> _share(Uint8List bytes) async {
    if (!Platform.isAndroid) return false;
    try {
      final shared =
          await _android.invokeMethod<bool>('shareFile', {
            'name': PairingFile.fileName,
            'bytes': bytes,
            'title': 'Send to your computer',
          }) ??
          false;
      if (shared) {
        unawaited(Future<void>.delayed(PairingHost.defaultFileWindow, _forget));
      }
      return shared;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> _forget() async {
    try {
      await _android.invokeMethod<bool>('forgetSharedFile');
    } on PlatformException {
      // Replaced by the next file anyway.
    } on MissingPluginException {
      // Not on a device.
    }
  }
}
