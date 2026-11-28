// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app/app.dart';
import 'src/background/background_mail.dart';
import 'src/features/accounts/state/oauth_browser.dart';

export 'src/app/app.dart' show CitusmailApp, appName;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    OAuthBrowser.listenForAndroidAnswers();
    // Edge to edge on every Android version, as Android 15 and later
    // require: the app draws under the system bars, and every screen
    // keeps its content clear of them by the room they take on this
    // phone (SafeArea, the sheets' insets), not by a fixed size.
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  LicenseRegistry.addLicense(_fontLicense);
  runApp(const CitusmailApp());
}

/// The bundled typeface's licence, shown on the licences page.
Stream<LicenseEntry> _fontLicense() async* {
  yield LicenseEntryWithLineBreaks(const [
    'IBM Plex Sans',
  ], await rootBundle.loadString('assets/fonts/IBMPlexSans/OFL.txt'));
}

/// Android: the periodic background check (started by BackgroundSyncWorker).
@pragma('vm:entry-point')
Future<void> backgroundSyncMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundMail.runOnce();
}

/// Android: "Instant mail" (started by InstantMailService).
@pragma('vm:entry-point')
Future<void> instantMailMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundMail.runInstant();
}
