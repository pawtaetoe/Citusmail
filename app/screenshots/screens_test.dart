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

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/setup/setup_controller.dart';
import 'package:citusmail/src/setup/setup_page.dart';
import 'package:citusmail/src/ui/accounts_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/subscriptions_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import '../test/support/test_app.dart';

/// Fonts the app ships or the platform gives, so text renders as text.
Future<void> _loadFonts() async {
  final flutter =
      Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/development/flutter';
  final cache = '$flutter/bin/cache/artifacts/material_fonts';
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
          theme: CitusmailTheme.light(),
          darkTheme: CitusmailTheme.dark(),
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

  // The README's demo screens: a fuller inbox with made-up senders.
  // SCREEN_OUT=../docs/screenshots flutter test screenshots/screens_test.dart --plain-name readme
  for (final (name, size) in [
    ('readme_desktop', const Size(1440, 860)),
    ('readme_phone', const Size(390, 844)),
  ]) {
    testWidgets('readme $name', (tester) async {
      _seedDemo(app.store);
      await show(tester, shell(), size: size, dark: true);
      await shoot(tester, name);
    });
  }

  // More README screens, from the same made-up mail.
  testWidgets('readme gallery', (tester) async {
    _seedDemo(app.store);
    app.seedFixture(
      'security/org-impersonation-form.eml',
      subject:
          'STUDENT NOTICE - 2026 Skills Program x East Institute of Technology',
      uid: 90,
      receivedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );

    // A scam from a real, verified address: the warning says why.
    await show(tester, shell(), size: const Size(1440, 860), dark: true);
    await tester.tap(find.textContaining('STUDENT NOTICE').first);
    await shoot(tester, 'readme_phishing');

    // Phone: the same message, its actions at the bottom.
    await show(tester, shell(), size: const Size(390, 844), dark: true);
    await shoot(tester, 'readme_phone_reader');

    // Phone: writing, Send at the bottom.
    await tester.tap(find.byTooltip('Back (Esc)'));
    await settle(tester);
    await tester.tap(find.byTooltip('New message (C)'));
    await shoot(tester, 'readme_phone_compose');
  });

  testWidgets('readme settings', (tester) async {
    await show(
      tester,
      SettingsPage(services: app.services, isAndroid: true),
      size: const Size(390, 844),
      dark: true,
    );
    await shoot(tester, 'readme_phone_settings');
  });

  testWidgets('readme subscriptions', (tester) async {
    _seedSubscriptions(app.store);
    await show(
      tester,
      SubscriptionsPage(controller: MailController(app.services)),
      size: const Size(390, 844),
      dark: true,
    );
    await shoot(tester, 'readme_subscriptions');
    await tester.tap(find.text('StreamFlix').last);
    await shoot(tester, 'readme_subscription');
  });

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('accounts $name', (tester) async {
      _seedAccounts(app.store);
      await show(
        tester,
        AccountsPage(controller: MailController(app.services)),
        size: size,
      );
      await shoot(tester, '${name}_accounts');
      await tester.tap(find.text('GitHub'));
      await shoot(tester, '${name}_account');
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

/// Made-up receipts for the Subscriptions screen.
void _seedSubscriptions(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now().toUtc();
  var uid = 400;
  MessageSummary receipt(
    String domain,
    String name,
    String subject,
    int daysAgo,
    String snippet,
  ) => MessageSummary(
    uid: uid++,
    receivedAt: now.subtract(Duration(days: daysAgo)),
    subject: subject,
    from: MailAddress(localPart: 'billing', domain: domain, displayName: name),
    snippet: snippet,
    flags: MessageFlags.fromImap([r'\Seen']),
  );
  store.messages.upsertSummaries(inbox.id, [
    for (final d in [117, 147])
      receipt(
        'streamflix.example',
        'StreamFlix',
        'Your StreamFlix receipt',
        d,
        'Your membership has been renewed. Total S\$15.98',
      ),
    for (final d in [27, 57, 87])
      receipt(
        'streamflix.example',
        'StreamFlix',
        'Your StreamFlix receipt',
        d,
        'Your membership has been renewed. Total S\$17.98',
      ),
    for (final d in [12, 42, 72])
      receipt(
        'tunes.example',
        'Tunes',
        'Tunes Premium receipt',
        d,
        'Subscription renewed. You paid S\$11.98',
      ),
    receipt(
      'cloudbox.example',
      'CloudBox',
      'Receipt for your subscription',
      200,
      'Plus plan, billed yearly. Total US\$119.88',
    ),
    for (final d in [150, 180])
      receipt(
        'gym.example',
        'City Gym',
        'Membership payment received',
        d,
        'Amount charged S\$89.00',
      ),
    receipt(
      'gym.example',
      'City Gym',
      'Your membership has been cancelled',
      140,
      '',
    ),
  ]);
}

/// Made-up account mail for the "Your accounts" screen.
void _seedAccounts(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now().toUtc();
  var uid = 600;
  MessageSummary mail(
    String from,
    String name,
    String subject,
    int daysAgo, {
    String to = 'alice@citusmail.test',
    String? snippet,
  }) {
    final at = from.indexOf('@');
    final toAt = to.indexOf('@');
    return MessageSummary(
      uid: uid++,
      receivedAt: now.subtract(Duration(days: daysAgo)),
      subject: subject,
      from: MailAddress(
        localPart: from.substring(0, at),
        domain: from.substring(at + 1),
        displayName: name,
      ),
      to: [
        MailAddress(
          localPart: to.substring(0, toAt),
          domain: to.substring(toAt + 1),
        ),
      ],
      snippet: snippet,
      flags: MessageFlags.fromImap([r'\Seen']),
    );
  }

  store.messages.upsertSummaries(inbox.id, [
    mail('no-reply@accounts.google.com', 'Google', 'Security alert', 3),
    mail(
      'no-reply@accounts.google.com',
      'Google',
      'Welcome to your new Google Account',
      2050,
    ),
    mail(
      'noreply@github.com',
      'GitHub',
      '[GitHub] Please verify your email address',
      1700,
    ),
    mail(
      'noreply@github.com',
      'GitHub',
      '[GitHub] A new SSH key was added to your account',
      40,
    ),
    mail(
      'noreply@github.com',
      'GitHub',
      '[GitHub] Please reset your password',
      300,
    ),
    mail(
      'noreply@github.com',
      'GitHub',
      'Your GitHub launch code',
      12,
      snippet: 'Here is your GitHub launch code: 48213907',
    ),
    mail('info@mailer.netflix.com', 'Netflix', 'Your Netflix sign-in code', 20),
    mail('info@mailer.netflix.com', 'Netflix', 'Welcome to Netflix!', 1300),
    for (final d in [25, 55, 85])
      mail(
        'info@mailer.netflix.com',
        'Netflix',
        'Your Netflix receipt',
        d,
        snippet: 'Your membership has been renewed. Total S\$17.98',
      ),
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Please confirm your Shopee account',
      1330,
      to: 'alice+shopee@citusmail.test',
    ),
    mail(
      'info@mail.shopee.sg',
      'Shopee',
      'Your OTP for Shopee',
      60,
      to: 'alice+shopee@citusmail.test',
      snippet: 'Your Shopee OTP is 553201. It expires in 5 minutes.',
    ),
    mail(
      'no-reply@grab.com',
      'Grab',
      'Welcome to Grab!',
      1500,
      snippet: 'Thanks for signing up. Your account is ready.',
    ),
    mail('no-reply@grab.com', 'Grab', 'New login to your Grab account', 110),
    mail(
      'alerts@northwind.example',
      'Northwind Bank',
      'New device registered',
      200,
    ),
    mail(
      'alerts@northwind.example',
      'Northwind Bank',
      'Your account statement for September',
      34,
    ),
    mail('team@oldforum.example', 'OldForum', 'Welcome to OldForum', 3600),
    mail(
      'team@oldforum.example',
      'OldForum',
      'Your password was changed',
      2900,
    ),
    mail('team@photostash.example', 'PhotoStash', 'Verify your email', 2400),
    mail(
      'team@photostash.example',
      'PhotoStash',
      'Your account has been deleted',
      900,
    ),
  ]);
}

/// Made-up mail for the demo screens.
void _seedDemo(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now().toUtc();
  MailAddress who(String address, String name) {
    final at = address.indexOf('@');
    return MailAddress(
      localPart: address.substring(0, at),
      domain: address.substring(at + 1),
      displayName: name,
    );
  }

  var uid = 200;
  MessageSummary mail(
    int minutesAgo,
    String from,
    String name,
    String subject, {
    String? snippet,
    MessageCategory category = MessageCategory.general,
    String? code,
    bool seen = false,
  }) => MessageSummary(
    uid: uid++,
    receivedAt: now.subtract(Duration(minutes: minutesAgo)),
    subject: subject,
    from: who(from, name),
    snippet: snippet,
    category: category,
    code: code,
    flags: MessageFlags.fromImap([if (seen) r'\Seen']),
  );

  // The test inbox's "Stranger Danger", under a friendlier name.
  final hello = store.messages.byUid(inbox.id, 1)!;
  store.messages.upsertSummaries(inbox.id, [
    MessageSummary(
      uid: 1,
      receivedAt: hello.receivedAt,
      subject: 'Photos from the trip',
      from: who('sam@contoso.example', 'Sam Rivera'),
      snippet: 'Here are the best ones. The lake at sunrise is my favourite.',
    ),
  ]);
  store.messages.upsertSummaries(inbox.id, [
    mail(
      2,
      'no-reply@northwind.example',
      'Northwind Bank',
      'Your sign-in code',
      category: MessageCategory.codes,
      code: '482913',
    ),
    mail(
      9,
      'accounts@tailspin.example',
      'Tailspin',
      'Reset your password',
      snippet: 'Someone asked to reset the password for your account.',
      category: MessageCategory.codes,
      code: '',
      seen: true,
    ),
    mail(
      14,
      'maya@fabrikam.example',
      'Maya Chen',
      'Design review moved to Thursday',
      snippet: 'Same room, 3pm. I have attached the latest mockups.',
    ),
    mail(
      40,
      'jon@contoso.example',
      'Jon Park',
      'Weekend hike?',
      snippet: 'Weather looks good for Saturday. Leaving at 8 from the lake.',
    ),
    mail(
      95,
      'news@adventure.example',
      'Adventure Works',
      'Autumn trail guide',
      category: MessageCategory.newsletters,
    ),
    mail(
      130,
      'noreply@parcel.example',
      'Parcel Co',
      'Your parcel is out for delivery',
      category: MessageCategory.notifications,
    ),
  ]);
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
