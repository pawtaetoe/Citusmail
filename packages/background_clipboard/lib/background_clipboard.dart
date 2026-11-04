// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Clipboard writes that also work without an app window (Android: from a
/// notification button handled in the background).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puts text on the clipboard.
///
/// On Android this goes through a small plugin that uses the application
/// context, so it works in the headless engine Android starts for a
/// notification action. Elsewhere it is Flutter's [Clipboard] (there the
/// app window is open whenever a notification action arrives).
abstract final class BackgroundClipboard {
  static const _channel = MethodChannel('citusmail/background-clipboard');

  /// Copies [text]. With [sensitive], Android 13+ hides it in its clipboard
  /// preview. [confirmation] is shown as a short toast where the system does
  /// not confirm a copy itself (Android 12 and older).
  static Future<void> copy(
    String text, {
    String label = '',
    bool sensitive = false,
    String? confirmation,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
      await _channel.invokeMethod<bool>('copy', {
        'text': text,
        'label': label,
        'sensitive': sensitive,
        'confirmation': ?confirmation,
      });
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
  }
}
