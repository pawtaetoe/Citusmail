// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

/// Light, dark, or as the device is: chosen in Settings, Appearance.
abstract final class Appearance {
  /// The choice, by name (`light`, `dark`, `system`).
  static const setting = EnumSetting(
    'app.theme',
    ThemeMode.values,
    fallback: ThemeMode.system,
  );

  /// What the app shows; the app rebuilds when it changes.
  static final theme = ValueNotifier<ThemeMode>(ThemeMode.system);

  static ThemeMode read(MailStore store) => setting.read(store.settings);

  /// At start: the stored choice.
  static void load(MailStore store) => theme.value = read(store);

  static void choose(MailStore store, ThemeMode mode) {
    setting.write(store.settings, mode);
    theme.value = mode;
  }

  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Automatic',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}
