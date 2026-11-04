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
import 'package:citusmail/src/ui/attachments_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/deliveries_page.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/privacy_report_page.dart';
import 'package:citusmail/src/ui/sender_cleanup_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/subscriptions_page.dart';
import 'package:citusmail/src/ui/trips_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import '../test/support/delivery_mail.dart';
import '../test/support/privacy_mail.dart';
import '../test/support/return_mail.dart';
import '../test/support/sample_files.dart';
import '../test/support/test_app.dart';
import '../test/support/trip_mail.dart';

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
    for (final dark in [false, true]) {
      testWidgets('deliveries $name${dark ? ' dark' : ''}', (tester) async {
        seedDeliveries(app.store, now: DateTime.now().toUtc());
        await show(
          tester,
          DeliveriesPage(controller: MailController(app.services)),
          size: size,
          dark: dark,
        );
        final suffix = dark ? '_dark' : '';
        await shoot(tester, '${name}_deliveries$suffix');
        await tester.tap(find.text('Amazon.sg'));
        await shoot(tester, '${name}_delivery$suffix');
      });
    }
  }

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('trips $name${dark ? ' dark' : ''}', (tester) async {
        seedTrips(app.store, now: DateTime.now().toUtc());
        await show(
          tester,
          TripsPage(controller: MailController(app.services)),
          size: size,
          dark: dark,
        );
        final suffix = dark ? '_dark' : '';
        await shoot(tester, '${name}_trips$suffix');
        await tester.tap(find.text('Flight to Tokyo'));
        await shoot(tester, '${name}_booking$suffix');
      });
    }
  }

  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('returns $name${dark ? ' dark' : ''}', (tester) async {
        final now = DateTime.now().toUtc();
        seedDeliveries(app.store, now: now);
        seedReturns(app.store, now: now);
        await show(
          tester,
          DeliveriesPage(controller: MailController(app.services)),
          size: size,
          dark: dark,
        );
        final suffix = dark ? '_dark' : '';
        await tester.scrollUntilVisible(
          find.text('Can still be returned'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 40));
        await shoot(tester, '${name}_returns$suffix');
        await tester.tap(
          find.byKey(const ValueKey('delivery-t:NVSGAMZ0099887766')),
        );
        await shoot(tester, '${name}_return_delivery$suffix');
      });
    }
  }

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

  testWidgets('subscriptions coming up', (tester) async {
    _seedSubscriptions(app.store);
    _seedReminders(app.store);
    for (final (name, size, dark) in [
      ('phone_coming_up', const Size(390, 844), false),
      ('phone_coming_up_dark', const Size(390, 844), true),
      ('desktop_coming_up', const Size(1440, 900), false),
    ]) {
      await show(
        tester,
        SubscriptionsPage(
          key: ValueKey(name),
          controller: MailController(app.services),
        ),
        size: size,
        dark: dark,
      );
      await shoot(tester, name);
    }
  });

  testWidgets('clean up', (tester) async {
    _seedSenders(app.store);
    await show(
      tester,
      SenderCleanupPage(controller: MailController(app.services)),
      size: const Size(390, 844),
    );
    await shoot(tester, 'phone_clean_up');
    await tester.tap(find.text('ShopMart Deals'));
    await tester.tap(find.text('Daily Digest'));
    await shoot(tester, 'phone_clean_up_selected');
    await show(
      tester,
      SenderCleanupPage(controller: MailController(app.services)),
      size: const Size(1440, 900),
      dark: true,
    );
    await shoot(tester, 'desktop_clean_up_selected_dark');
    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.tap(find.text('Most mail'));
    await settle(tester);
    await tester.tap(find.text('Least opened').last);
    await settle(tester);
    await shoot(tester, 'desktop_clean_up_dark');
  });

  for (final dark in [false, true]) {
    final suffix = dark ? '_dark' : '';
    testWidgets('privacy report$suffix', (tester) async {
      seedPrivacyMail(app, DateTime.now().toUtc());
      Widget page() =>
          PrivacyReportPage(services: app.services, onShowMail: (_) {});
      await show(tester, page(), size: const Size(390, 844), dark: dark);
      await shoot(tester, 'phone_privacy_report$suffix');
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await shoot(tester, 'phone_privacy_report_end$suffix');
      await show(tester, page(), size: const Size(1200, 860), dark: dark);
      await shoot(tester, 'desktop_privacy_report$suffix');
    });
  }

  for (final (name, size, dark) in [
    ('phone', const Size(390, 844), false),
    ('phone_dark', const Size(390, 844), true),
    ('desktop', const Size(1440, 900), false),
  ]) {
    testWidgets('attachments $name', (tester) async {
      app.seedFiles();
      await show(
        tester,
        AttachmentsPage(controller: MailController(app.services)),
        size: size,
        dark: dark,
      );
      await shoot(tester, '${name}_attachments');
      await tester.tap(find.text('Beach.png'));
      await shoot(tester, '${name}_attachment_email');
    });
  }

  // Meeting invitations (samples in test-data/invites).
  testWidgets('invitation', (tester) async {
    app.seedFixture(
      '../invites/outlook-teams-request.eml',
      subject: 'Q4 roadmap review',
      uid: 95,
      receivedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    app.seedFixture(
      '../invites/google-weekly-request.eml',
      subject: 'Invitation: Launch stand-up',
      uid: 96,
      receivedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    );
    app.seedFixture(
      '../invites/outlook-cancel.eml',
      subject: 'Canceled: Budget planning',
      uid: 97,
      receivedAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
    );
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.text('Q4 roadmap review').first);
    await shoot(tester, 'desktop_invitation');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Accept'));
    await shoot(tester, 'desktop_invitation_accepted');
    await tester.tap(find.text('Canceled: Budget planning').first);
    await shoot(tester, 'desktop_invitation_cancelled');

    await show(tester, shell(), size: const Size(390, 844), dark: true);
    // The same shell, still showing the cancelled event: back to the list.
    await tester.tap(find.byTooltip('Back (Esc)'));
    await settle(tester);
    await tester.tap(find.text('Invitation: Launch stand-up').first);
    await shoot(tester, 'phone_invitation');
  });

  testWidgets('settings', (tester) async {
    await show(
      tester,
      SettingsPage(services: app.services, isAndroid: true),
      size: const Size(390, 844),
    );
    await shoot(tester, 'phone_settings');
  });

  // The Google Play build (no Instant mail), tall enough for About.
  testWidgets('settings play', (tester) async {
    await show(
      tester,
      SettingsPage(services: app.services, isAndroid: true, playBuild: true),
      size: const Size(390, 1700),
    );
    await shoot(tester, 'phone_settings_play');
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

  // Old verification codes: the question in the Verification section,
  // the notice after tidying up, and the setting.
  testWidgets('code cleanup', (tester) async {
    _seedDemo(app.store);
    _seedOldCodes(app.store);
    await show(tester, shell(), size: const Size(1440, 900));
    await shoot(tester, 'desktop_code_cleanup');
    await show(tester, shell(), size: const Size(390, 844), dark: true);
    await shoot(tester, 'phone_code_cleanup');
    await tester.tap(find.text('Turn on'));
    await tester.pump();
    await shoot(tester, 'phone_code_cleanup_done');
    await show(
      tester,
      SettingsPage(services: app.services, isAndroid: true),
      size: const Size(390, 844),
    );
    await tester.scrollUntilVisible(find.text('Clean up old codes'), 300);
    await shoot(tester, 'phone_code_cleanup_settings');
    await tester.tap(find.text('Clean up old codes'));
    await shoot(tester, 'phone_code_cleanup_dialog');
  });

  testWidgets('compose', (tester) async {
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.byTooltip('New message (C)'));
    await shoot(tester, 'desktop_compose');
  });

  // The Screener: the entry at the top of the inbox, the page (buttons
  // per sender on the desktop, a bottom bar on phones), and Settings.
  testWidgets('screener', (tester) async {
    _seedDemo(app.store);
    _seedScreener(app.store);
    await show(tester, shell(), size: const Size(1440, 900));
    await shoot(tester, 'desktop_screener_inbox');
    await tester.tap(find.text('Screener'));
    await shoot(tester, 'desktop_screener');
    await tester.pageBack();
    await show(tester, shell(), size: const Size(390, 844), dark: true);
    await shoot(tester, 'phone_screener_inbox');
    await tester.tap(find.text('Screener'));
    await shoot(tester, 'phone_screener');
    await tester.pageBack();
    await show(tester, shell(), size: const Size(390, 844));
    await tester.tap(find.text('Screener'));
    await shoot(tester, 'phone_screener_light');
    await tester.pageBack();
    await show(
      tester,
      SettingsPage(services: app.services, isAndroid: true),
      size: const Size(390, 844),
    );
    await tester.scrollUntilVisible(
      find.text('Screen first-time senders'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await shoot(tester, 'phone_screener_settings');
  });
}

/// Turns the Screener on after the demo inbox (whose senders count as
/// let in), then three first-time senders write.
void _seedScreener(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  store.screener.enable();
  final since = store.screener.since!;
  MailAddress who(String address, String name) => MailAddress(
    localPart: address.substring(0, address.indexOf('@')),
    domain: address.substring(address.indexOf('@') + 1),
    displayName: name,
  );
  var uid = 400;
  MessageSummary mail(
    int minutesAfter,
    MailAddress from,
    String subject,
    String snippet,
  ) => MessageSummary(
    uid: uid++,
    receivedAt: since.add(Duration(minutes: minutesAfter)),
    subject: subject,
    from: from,
    snippet: snippet,
    messageId: 'screener$uid@demo.example',
  );
  final ana = who('ana.ruiz@studio-north.example', 'Ana Ruiz');
  store.messages.upsertSummaries(inbox.id, [
    mail(
      1,
      ana,
      'Portfolio review?',
      'Hi! I saw your talk at the design meetup last week and wondered if '
          'you had 20 minutes to look at my portfolio.',
    ),
    mail(
      2,
      who('hello@brightlane-realty.example', 'Brightlane Realty'),
      'Is your home worth more than you think?',
      'Get a free valuation in 2 minutes. Homes on your street sold for '
          '12% more this year.',
    ),
    mail(
      3,
      who('m.okafor@harbourschool.example', 'Mr Okafor'),
      'Year 5 trip: consent form',
      'Dear parents, the Year 5 trip to the science museum is on 14 '
          'November. Please return the consent form by Friday.',
    ),
    mail(
      4,
      ana,
      'Following up',
      'Just making sure this reached you. No rush at all!',
    ),
  ]);
}

/// Made-up bulk mail for the Clean up screen: per sender, how many in
/// the last weeks and how many of them were read.
void _seedSenders(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now().toUtc();
  var uid = 600;
  final senders = [
    ('deals', 'shopmart.example', 'ShopMart Deals', 64, 2, true, false),
    ('digest', 'dailydigest.example', 'Daily Digest', 45, 3, true, false),
    ('no-reply', 'cloudco.example', 'CloudCo', 30, 21, false, true),
    ('notifications', 'cloudco.example', 'CloudCo', 12, 9, true, true),
    ('hello', 'fitapp.example', 'FitApp', 18, 0, true, false),
    ('news', 'citylibrary.example', 'City Library', 9, 8, true, false),
    ('offers', 'airline.example', 'SkyAir Offers', 3, 0, true, false),
  ];
  store.messages.upsertSummaries(inbox.id, [
    for (final (local, domain, name, count, read, unsub, notify) in senders)
      for (var i = 0; i < count; i++)
        MessageSummary(
          uid: uid++,
          receivedAt: now.subtract(Duration(hours: 6 + i * 30)),
          subject: '$name update ${i + 1}',
          from: MailAddress(
            localPart: local,
            domain: domain,
            displayName: name,
          ),
          category: notify
              ? MessageCategory.notifications
              : MessageCategory.newsletters,
          flags: MessageFlags.fromImap([if (i < read) r'\Seen']),
          headers: {
            if (unsub) 'list-unsubscribe': ['<https://$domain/unsubscribe>'],
          },
        ),
  ]);
}

/// Made-up verification codes from earlier in the week.
void _seedOldCodes(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now().toUtc();
  var uid = 500;
  MessageSummary code(String domain, String name, String subject, int hours) =>
      MessageSummary(
        uid: uid++,
        receivedAt: now.subtract(Duration(hours: hours)),
        subject: subject,
        from: MailAddress(
          localPart: 'no-reply',
          domain: domain,
          displayName: name,
        ),
        category: MessageCategory.codes,
        code: '${730000 + hours}',
        flags: MessageFlags.fromImap([r'\Seen']),
      );
  store.messages.upsertSummaries(inbox.id, [
    code('northwind.example', 'Northwind Bank', 'Your sign-in code', 30),
    code('tailspin.example', 'Tailspin', 'Confirm your email', 52),
    code('wingtip.example', 'Wingtip Toys', 'Your one-time code', 75),
    code('northwind.example', 'Northwind Bank', 'Your sign-in code', 98),
  ]);
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

/// Made-up bills and a free trial for "Coming up".
void _seedReminders(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now();
  String date(DateTime d) => '${d.day}/${d.month}/${d.year}';
  var uid = 450;
  MessageSummary mail(
    String domain,
    String name,
    String subject,
    int daysAgo,
    String snippet,
  ) => MessageSummary(
    uid: uid++,
    receivedAt: now.subtract(Duration(days: daysAgo)).toUtc(),
    subject: subject,
    from: MailAddress(localPart: 'billing', domain: domain, displayName: name),
    snippet: snippet,
  );
  store.messages.upsertSummaries(inbox.id, [
    mail(
      'myrepublic.example',
      'MyRepublic',
      'Your MyRepublic e-Bill is ready!',
      4,
      'The outstanding amount for your account is: \$32.99. Please pay your '
          'bill within 7 days of receiving this email.',
    ),
    mail(
      'citypower.example',
      'City Power',
      'Your electricity bill for this month',
      3,
      'Total amount due: S\$84.20. Due date: '
          '${date(now.add(const Duration(days: 9)))}',
    ),
    mail(
      'pandapro.example',
      'foodpanda',
      'Your pandapro free trial is ending',
      1,
      'Your free trial ends in 2 days, then S\$59.88/year.',
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
