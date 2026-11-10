// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

/// Light, dark, or as the device is: chosen in Settings, Appearance.
abstract final class Appearance {
  static const key = 'app.theme';

  /// What the app shows; the app rebuilds when it changes.
  static final theme = ValueNotifier<ThemeMode>(ThemeMode.system);

  static ThemeMode read(MailStore store) => switch (store.settings.read(key)) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  /// At start: the stored choice.
  static void load(MailStore store) => theme.value = read(store);

  static void choose(MailStore store, ThemeMode mode) {
    store.settings.write(key, mode.name);
    theme.value = mode;
  }

  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Automatic',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}
