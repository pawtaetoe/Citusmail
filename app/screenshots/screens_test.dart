// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Renders the main screens to PNG files with real fonts, for design
// reviews (not part of the test suite):
//
//   flutter test screenshots/screens_test.dart
//
// Files go to build/screens/ (or $SCREEN_OUT).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/setup/setup_controller.dart';
import 'package:fmail/src/setup/setup_page.dart';
import 'package:fmail/src/ui/fmail_theme.dart';
import 'package:fmail/src/ui/mail_shell.dart';
import 'package:fmail/src/ui/settings_page.dart';
import 'package:mail_setup/mail_setup.dart';

import '../test/support/test_app.dart';

/// Fonts the app ships or the platform gives, so text renders as text.
Future<void> _loadFonts() async {
  final home = Platform.environment['HOME']!;
  final cache = '$home/development/flutter/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final w in ['Regular', 'Medium', 'Bold', 'Italic', 'Light'])
      '$cache/Roboto-$w.ttf',
  ]);
  await load('MaterialIcons', ['$cache/MaterialIcons-Regular.otf']);
  for (final (family, files) in _extraFonts) {
    final present = files.where((f) => File(f).existsSync()).toList();
    if (present.isNotEmpty) await load(family, present);
  }
}

/// Fonts bundled with the app (asset fonts), loaded by family name.
final _extraFonts = <(String, List<String>)>[
  for (final dir in [Directory('assets/fonts')])
    if (dir.existsSync())
      for (final family in dir.listSync().whereType<Directory>())
        (
          family.uri.pathSegments.where((s) => s.isNotEmpty).last,
          [
            for (final f in family.listSync().whereType<File>())
              if (f.path.endsWith('.ttf') || f.path.endsWith('.otf')) f.path,
          ],
        ),
];

void main() {
  final out = Directory(Platform.environment['SCREEN_OUT'] ?? 'build/screens')
    ..createSync(recursive: true);
  late TestApp app;

  setUpAll(_loadFonts);
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  final boundary = GlobalKey();

  Future<void> show(
    WidgetTester tester,
    Widget home, {
    required Size size,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: FmailTheme.light(),
          darkTheme: FmailTheme.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: home,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await settle(tester);
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final png = await tester.runAsync(() async {
      final image = await object.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    File('${out.path}/$name.png').writeAsBytesSync(png!);
  }

  Widget shell() => MailShell(
    notifications: false,
    services: app.services,
    onAddAccount: () {},
    onAccountsChanged: () {},
  );

  for (final dark in [false, true]) {
    final suffix = dark ? '_dark' : '';

    testWidgets('desktop inbox and reader$suffix', (tester) async {
      await show(tester, shell(), size: const Size(1440, 900), dark: dark);
      await shoot(tester, 'desktop_inbox$suffix');
      await tester.tap(find.text('Hello there'));
      await shoot(tester, 'desktop_reader$suffix');
    });

    testWidgets('phone inbox and reader$suffix', (tester) async {
      await show(tester, shell(), size: const Size(390, 844), dark: dark);
      await shoot(tester, 'phone_inbox$suffix');
      await tester.tap(find.text('Hello there'));
      await shoot(tester, 'phone_reader$suffix');
    });
  }

  testWidgets('settings', (tester) async {
    await show(
      tester,
      SettingsPage(services: app.services, isAndroid: true),
      size: const Size(390, 844),
    );
    await shoot(tester, 'phone_settings');
  });

  testWidgets('setup', (tester) async {
    await show(
      tester,
      SetupPage(
        controller: SetupController(
          discover: (email, {askMozillaConsent, onStep}) async =>
              const DiscoveryResult(null),
          verify: (s, p) async => const VerificationResult.success(),
          save: (s, p, {displayName}) async => throw UnimplementedError(),
        ),
        onDone: (_) {},
      ),
      size: const Size(1440, 900),
    );
    await shoot(tester, 'desktop_setup');
  });

  testWidgets('compose', (tester) async {
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.byTooltip('New message (C)'));
    await shoot(tester, 'desktop_compose');
  });
}

/// Lets isolates (message parsing) finish and animations end.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}
