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

import 'package:citusmail/src/compose/compose_controller.dart';
import 'package:citusmail/src/compose/compose_page.dart';
import 'package:citusmail/src/mail/corrections.dart';
import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/mail/new_since_away.dart';
import 'package:citusmail/src/mail/send_later_times.dart';
import 'package:citusmail/src/pairing/receive_accounts_page.dart';
import 'package:citusmail/src/pairing/send_accounts_page.dart';
import 'package:citusmail/src/setup/setup_controller.dart';
import 'package:citusmail/src/setup/setup_page.dart';
import 'package:citusmail/src/ui/accounts_page.dart';
import 'package:citusmail/src/ui/appointments_page.dart';
import 'package:citusmail/src/ui/attachments_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/deliveries_page.dart';
import 'package:citusmail/src/ui/device_sync_page.dart';
import 'package:citusmail/src/ui/discover_page.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/privacy_report_page.dart';
import 'package:citusmail/src/ui/sender_cleanup_page.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:citusmail/src/ui/sign_offs_page.dart';
import 'package:citusmail/src/ui/subscriptions_page.dart';
import 'package:citusmail/src/ui/trips_page.dart';
import 'package:citusmail/src/ui/whats_new.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_ai/testing.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_pairing/mail_pairing.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../test/support/appointment_mail.dart';
import '../test/support/away_mail.dart';
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
    // SCREEN_PHONE=play: phones at 16:9 instead, for the Google Play
    // listing (Play takes at most 2:1; 390 x 844 is 2.16).
    final shown =
        Platform.environment['SCREEN_PHONE'] == 'play' &&
            size == const Size(390, 844)
        ? const Size(412, 732)
        : size;
    tester.view.physicalSize = shown * 2;
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
    // Tests draw shadows as solid outlines; a screenshot shows them as the
    // app does, and the setting is back before the test ends.
    final object =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    debugDisableShadows = false;
    _repaint(object);
    await tester.pump();
    final png = await tester.runAsync(() async {
      final image = await object.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    debugDisableShadows = true;
    _repaint(object);
    await tester.pump();
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
      SettingsPage(
        services: app.services,
        controller: MailController(app.services),
        isAndroid: true,
      ),
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

  // Reading receipts automatically: a quiet line while receipts not on
  // the device yet are read, instead of the "Read receipts" card; the
  // switch in Settings.
  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('read ahead $name', (tester) async {
      _seedSubscriptions(app.store);
      final inbox = app.store.mailboxes.inbox(
        app.store.accounts.all().single.id,
      )!;
      app.store.messages.upsertSummaries(inbox.id, [
        for (final (i, company) in ['PhotoVault', 'NoteCloud'].indexed)
          MessageSummary(
            uid: 480 + i,
            receivedAt: DateTime.now().toUtc().subtract(Duration(days: 3 + i)),
            subject: 'Your receipt from $company',
            from: MailAddress(
              displayName: company,
              localPart: 'billing',
              domain: '${company.toLowerCase()}.example',
            ),
            snippet: 'Thanks for your payment.',
          ),
      ]);
      await show(
        tester,
        SubscriptionsPage(controller: MailController(app.services)),
        size: size,
      );
      // As in the app: reading starts a little after it opens.
      app.services.autoRead.start(const Stream.empty());
      await shoot(tester, '${name}_read_ahead');
      app.services.autoRead.stop();
    });
  }

  testWidgets('read ahead setting', (tester) async {
    await show(
      tester,
      SettingsPage(
        services: app.services,
        controller: MailController(app.services),
        isAndroid: true,
      ),
      size: const Size(390, 844),
    );
    await tester.tap(find.text('Inbox & sorting'));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Read receipts and bookings automatically'),
      300,
    );
    await shoot(tester, 'phone_read_ahead_setting');
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
      testWidgets('appointments $name${dark ? ' dark' : ''}', (tester) async {
        seedAppointments(app.store, now: DateTime.now().toUtc());
        await show(
          tester,
          AppointmentsPage(controller: MailController(app.services)),
          size: size,
          dark: dark,
        );
        final suffix = dark ? '_dark' : '';
        await shoot(tester, '${name}_appointments$suffix');
        await tester.tap(find.text('Bright Smile Dental'));
        await shoot(tester, '${name}_appointment$suffix');
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

  // The sidebar's groups, and Files in search (where Attachments went).
  for (final dark in [false, true]) {
    final suffix = dark ? '_dark' : '';
    testWidgets('sidebar$suffix', (tester) async {
      app.seedFiles();
      await show(tester, shell(), size: const Size(1440, 900), dark: dark);
      await tester.tap(find.widgetWithText(TextField, 'Search mail'));
      await shoot(tester, 'desktop_search_files$suffix');

      await show(tester, shell(), size: const Size(390, 844), dark: dark);
      await tester.tap(find.widgetWithText(TextField, 'Search mail'));
      await shoot(tester, 'phone_search_files$suffix');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
      await shoot(tester, 'phone_sidebar$suffix');
    });
  }

  // The sidebar with two accounts: folded, with their unread counts;
  // then one account and both feature groups open; the phone drawer.
  for (final dark in [false, true]) {
    final suffix = dark ? '_dark' : '';
    testWidgets('sidebar accounts$suffix', (tester) async {
      _seedSecondAccount(app.store);
      Finder fold(String label) => find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == label,
      );
      await show(tester, shell(), size: const Size(1440, 900), dark: dark);
      await shoot(tester, 'desktop_sidebar_folded$suffix');
      for (final label in [
        'Show folders of alice@citusmail.test',
        'Show Found in your mail',
        'Show Tools',
      ]) {
        await tester.tap(fold(label));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Projects'));
      await shoot(tester, 'desktop_sidebar_open$suffix');

      await show(tester, shell(), size: const Size(390, 844), dark: dark);
      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
      await shoot(tester, 'phone_drawer$suffix');
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
      SettingsPage(
        services: app.services,
        controller: MailController(app.services),
        isAndroid: true,
      ),
      size: const Size(390, 844),
    );
    await shoot(tester, 'phone_settings');
  });

  // Sync between devices: what syncs and what stays on each device.
  testWidgets('device sync', (tester) async {
    await show(
      tester,
      DeviceSyncPage(services: app.services),
      size: const Size(390, 1100),
    );
    await shoot(tester, 'phone_device_sync');
  });

  // Easier to find: Settings by what people want to do, with a search;
  // all features in one place; what is new after an update; a tip.
  testWidgets('discoverability', (tester) async {
    _seedDemo(app.store);
    final controller = MailController(app.services);
    Widget settings() => SettingsPage(
      services: app.services,
      controller: controller,
      isAndroid: true,
    );
    Future<void> searchFor(String words) async {
      await tester.tap(find.byKey(const ValueKey('settings-search')));
      await settle(tester);
      await tester.enterText(find.byType(TextField), words);
      await settle(tester);
    }

    // Phone: the groups, one group, the search.
    await show(tester, settings(), size: const Size(390, 844));
    await shoot(tester, 'phone_settings_groups');
    await tester.tap(find.text('Notifications & checking mail'));
    await shoot(tester, 'phone_settings_notifications');
    await tester.pageBack();
    await settle(tester);
    await searchFor('dark mode');
    await shoot(tester, 'phone_settings_search');
    await tester.tap(find.widgetWithText(ListTile, 'Theme'));
    await shoot(tester, 'phone_settings_found');

    // Desktop: groups beside the settings; a search, and what it found.
    await tester.pumpWidget(const SizedBox());
    await show(tester, settings(), size: const Size(1440, 900));
    await shoot(tester, 'desktop_settings');
    await searchFor('pin');
    await shoot(tester, 'desktop_settings_search');
    await tester.tap(find.widgetWithText(ListTile, 'App lock').last);
    await shoot(tester, 'desktop_settings_found');
    await tester.pumpWidget(const SizedBox());
    await show(tester, settings(), size: const Size(1440, 900), dark: true);
    await shoot(tester, 'desktop_settings_dark');

    // All features.
    await show(
      tester,
      DiscoverPage(controller: controller, isAndroid: true),
      size: const Size(390, 844),
    );
    await shoot(tester, 'phone_discover');
    await show(
      tester,
      DiscoverPage(controller: controller, isAndroid: false),
      size: const Size(1440, 900),
    );
    await shoot(tester, 'desktop_discover');

    // What's new, after an update.
    app.store.settings.delete(WhatsNew.seenKey);
    await show(tester, shell(), size: const Size(1440, 900));
    await shoot(tester, 'desktop_whats_new');
    await show(tester, shell(), size: const Size(390, 844));
    await shoot(tester, 'phone_whats_new');
    await tester.tap(find.textContaining('more'));
    await shoot(tester, 'phone_whats_new_all');
    await tester.tap(find.text('Close'));
    await settle(tester);
    WhatsNew(app.store).markSeen();
  });

  // A tip, the first time it helps; the sync line's options.
  testWidgets('discoverability tip', (tester) async {
    app.seedFixture(
      'people/plain-text.eml',
      subject: 'Your flight booking to Lisbon',
      uid: 95,
      receivedAt: DateTime.now().toUtc(),
    );
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.text('Your flight booking to Lisbon').first);
    await shoot(tester, 'desktop_tip');
    await tester.tap(find.byTooltip('Notifications and checking mail'));
    await shoot(tester, 'desktop_checking_mail');
  });

  // Add accounts from your phone: the computer's code, and the phone
  // choosing what to send once connected.
  testWidgets('add accounts from your phone', (tester) async {
    final host = (await tester.runAsync(
      () => PairingHost.start(
        computerName: 'alice-laptop',
        addresses: [InternetAddress.loopbackIPv4],
        receive: (t) async => const [],
      ),
    ))!;
    await show(
      tester,
      ReceiveAccountsPage(services: app.services, startHost: (_) async => host),
      size: const Size(1440, 900),
    );
    await shoot(tester, 'desktop_add_from_phone');

    final phoneHost = (await tester.runAsync(
      () => PairingHost.start(
        computerName: 'alice-laptop',
        addresses: [InternetAddress.loopbackIPv4],
        receive: (t) async => const [],
      ),
    ))!;
    final store = app.store;
    for (final (email, name, host) in [
      ('alice@posteo.example', 'Alice (Posteo)', 'posteo.example'),
      ('alice.martin@work.example', 'Alice Martin', 'mail.work.example'),
    ]) {
      final account = store.accounts.add(
        NewAccount(
          email: email,
          displayName: name,
          username: email,
          imap: ServerSettings(
            host: host,
            port: 993,
            security: ConnectionSecurity.implicitTls,
          ),
          smtp: ServerSettings(
            host: host,
            port: 465,
            security: ConnectionSecurity.implicitTls,
          ),
        ),
      );
      await tester.runAsync(
        () => app.services.secrets.write(account.keychainKey, 'pw'),
      );
    }
    await tester.runAsync(
      () => app.services.secrets.write(
        store.accounts.all().first.keychainKey,
        'pw',
      ),
    );
    await show(
      tester,
      SendAccountsPage(
        services: app.services,
        phoneName: 'Pixel 8',
        scanner: (context, onCode) =>
            _AutoScan(text: phoneHost.offer.encode(), onCode: onCode),
      ),
      size: const Size(390, 844),
    );
    for (
      var i = 0;
      i < 40 && find.text('Accounts to send').evaluate().isEmpty;
      i++
    ) {
      await settle(tester);
    }
    await shoot(tester, 'phone_send_accounts');
    await tester.runAsync(host.close);
    await tester.runAsync(phoneHost.close);
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

  testWidgets('setup on a phone', (tester) async {
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
      size: const Size(390, 844),
    );
    await shoot(tester, 'phone_setup');
  });

  // Shared hosting: the certificate is for the hosting server, whose own
  // name is offered.
  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('setup hosting server $name', (tester) async {
      final controller = SetupController(
        discover: (email, {askMozillaConsent, onStep}) async =>
            const DiscoveryResult(null),
        verify: (s, p) async => VerificationResult.failure(
          ServerRole.imap,
          VerificationProblem.certificate,
          'Hostname mismatch',
          tlsFailure: TlsFailure.hostnameMismatch,
          certificate: RejectedCertificate(
            subject: '/CN=*.web-hosting.com',
            issuer: '/CN=Sectigo RSA Domain Validation',
            validFrom: DateTime(2026),
            validUntil: DateTime(2027),
          ),
        ),
        save: (s, p, {displayName}) async => throw UnimplementedError(),
        findHostingServer: (s, r) async => 'business905-5.web-hosting.com',
      );
      await controller.start(
        email: 'me@tommykung.cc',
        password: 'pw',
        askMozillaConsent: (_) async => false,
      );
      await controller.useSettings(
        DiscoveredSettings(
          email: 'me@tommykung.cc',
          imap: const ServerCandidate(
            'mail.tommykung.cc',
            993,
            ConnectionSecurity.implicitTls,
          ),
          smtp: const ServerCandidate(
            'mail.tommykung.cc',
            465,
            ConnectionSecurity.implicitTls,
          ),
          username: 'me@tommykung.cc',
          source: DiscoverySource.manual,
        ),
      );
      await show(
        tester,
        SetupPage(controller: controller, onDone: (_) {}),
        size: size,
      );
      await shoot(tester, '${name}_setup_hosting_server');
    });
  }

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
      SettingsPage(
        services: app.services,
        controller: MailController(app.services),
        isAndroid: true,
      ),
      size: const Size(390, 844),
    );
    await tester.tap(find.text('Inbox & sorting'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Clean up old codes'), 300);
    await shoot(tester, 'phone_code_cleanup_settings');
    await tester.tap(find.text('Clean up old codes'));
    await shoot(tester, 'phone_code_cleanup_dialog');
  });

  testWidgets('compose', (tester) async {
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.byTooltip('New message (C)'));
    await shoot(tester, 'desktop_compose');
    // A read receipt asked for: the labelled toggle filled in.
    await tester.tap(find.text('Receipt'));
    await shoot(tester, 'desktop_compose_receipt');
    // Let the draft's save timer run out.
    await tester.tap(find.byTooltip('Close (keeps the draft)'));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  // Sign-offs: a reply with the reply sign-off marked above the quote,
  // its menu, and the page that manages them (with each account's
  // defaults).
  testWidgets('sign-offs', (tester) async {
    final signOffs = app.store.signOffs;
    final work = signOffs.add(
      name: 'Work',
      text: 'Best regards,\nAlex Rivera\nRivera Studio',
    );
    signOffs.add(name: 'Casual', text: 'Cheers,\nAlex');
    final short = signOffs.add(name: 'Short', text: 'Thanks, Alex');
    final alice = app.store.accounts.all().single;
    signOffs.setDefaults(
      alice.email,
      SignOffDefaults(
        newMail: work.id,
        repliesSameAsNew: false,
        replies: short.id,
        changedAt: DateTime.utc(2026, 11, 10),
      ),
    );

    for (final (size, name) in [
      (const Size(1440, 900), 'desktop'),
      (const Size(390, 844), 'phone'),
    ]) {
      final controller = ComposeController(
        app.services,
        Draft(
          accountId: alice.id,
          to: const [
            MailAddress(
              displayName: 'Priya Shah',
              localPart: 'priya',
              domain: 'studio.example',
            ),
          ],
          subject: 'Re: Notes from Tuesday',
          body: 'Hi Priya,\n\nThursday at 10 works for me. See you then!',
          inReplyTo: 'notes-1@studio.example',
          quote:
              'On Tue, 10 Nov 2026 at 16:40, Priya Shah <priya@studio.example> '
              'wrote:\n> Could we meet on Thursday instead?\n>\n> Priya',
        ),
      );
      addTearDown(controller.dispose);
      await show(tester, ComposePage(controller: controller), size: size);
      await shoot(tester, '${name}_sign_off_compose');
      await tester.tap(find.byKey(const ValueKey('compose-sign-off')));
      await shoot(tester, '${name}_sign_off_menu');
      await tester.tap(find.text('Casual').last);
      await settle(tester);
      // Let the draft's save timer run out.
      await tester.pump(const Duration(seconds: 3));

      await show(tester, SignOffsPage(services: app.services), size: size);
      await shoot(tester, '${name}_sign_offs');
    }
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
      SettingsPage(
        services: app.services,
        controller: MailController(app.services),
        isAndroid: true,
      ),
      size: const Size(390, 844),
    );
    await tester.tap(find.text('Inbox & sorting'));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Screen first-time senders'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await shoot(tester, 'phone_screener_settings');
  });
  // Snooze: mail back from snooze on top of the inbox, the snooze choices
  // (a dialog on the desktop, a bottom sheet on phones), the Snoozed list.
  testWidgets('snooze', (tester) async {
    _seedDemo(app.store);
    _seedSnoozes(app.store);
    await show(tester, shell(), size: const Size(1440, 900));
    await shoot(tester, 'desktop_snooze_inbox');
    await tester.tap(find.text('Quarterly figures for the board'));
    await settle(tester);
    await tester.tap(find.byTooltip('Snooze (B)'));
    await shoot(tester, 'desktop_snooze_sheet');
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    await tester.tap(find.text('Snoozed').first);
    await settle(tester);
    await tester.tap(find.text('Draft contract for review'));
    await shoot(tester, 'desktop_snoozed');

    await tester.pumpWidget(const SizedBox()); // a fresh start
    await show(tester, shell(), size: const Size(390, 844));
    await tester.tap(find.text('Quarterly figures for the board'));
    await settle(tester);
    await tester.tap(find.byTooltip('Snooze (B)'));
    await shoot(tester, 'phone_snooze_sheet');
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    await tester.tap(find.byTooltip('Back (Esc)'));
    await settle(tester);
    await tester.tap(find.byTooltip('Folders'));
    await settle(tester);
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('Snoozed')),
    );
    await shoot(tester, 'phone_snoozed');
  });

  // Send later: the times next to Send (a dialog on the desktop, a bottom
  // sheet on phones), and scheduled messages waiting in the Outbox with
  // their actions and the note on when they really go.
  testWidgets('send later', (tester) async {
    final now = DateTime(2026, 11, 4, 9, 10); // a Wednesday morning
    SendLaterTimes.clock = () => now;
    addTearDown(() => SendLaterTimes.clock = DateTime.now);
    _seedDemo(app.store);
    _seedScheduledSends(app.store, app.services.sender, now);

    Future<void> writeOne({bool phoneShot = false}) async {
      await tester.tap(find.byTooltip('New message (C)'));
      await settle(tester);
      final fields = find.descendant(
        of: find.byType(ComposePage),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        fields.first,
        'Priya Shah <priya@studio.example>,',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Subject'),
        'Notes from Tuesday',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Write your message'),
        'Hi Priya,\n\nHere are my notes from Tuesday. Talk Monday!\n\nAlex',
      );
      if (phoneShot) await shoot(tester, 'phone_send_later_compose');
      await tester.tap(find.byTooltip('Send later'));
    }

    // The desktop notes, as on a computer.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await show(tester, shell(), size: const Size(1440, 900));
    await writeOne();
    await shoot(tester, 'desktop_send_later_menu');

    await tester.pumpWidget(const SizedBox()); // a fresh start
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.text('Outbox'));
    await settle(tester);
    await shoot(tester, 'desktop_send_later_outbox');
    await tester.tap(find.byTooltip('Scheduled message options').first);
    await shoot(tester, 'desktop_send_later_actions');
    debugDefaultTargetPlatformOverride = null;

    await tester.pumpWidget(const SizedBox());
    await show(tester, shell(), size: const Size(390, 844));
    await writeOne(phoneShot: true);
    await shoot(tester, 'phone_send_later_sheet');
    await tester.pump(const Duration(seconds: 3)); // the draft's autosave

    await tester.pumpWidget(const SizedBox());
    await show(tester, shell(), size: const Size(390, 844), dark: true);
    await tester.tap(find.byTooltip('Folders'));
    await settle(tester);
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('Outbox')),
    );
    await shoot(tester, 'phone_send_later_outbox');
  });

  // Read receipts: "Read by … on …" under the header of a sent email that
  // went to several people, "Read on …" for one person.
  testWidgets('read receipts', (tester) async {
    _seedReadReceipts(app.store);
    await show(tester, shell(), size: const Size(1440, 900));
    await tester.tap(find.text('Sent'));
    await settle(tester);
    await tester.tap(find.text('Quarterly plans'));
    await shoot(tester, 'desktop_read_receipts');

    await tester.pumpWidget(const SizedBox());
    await show(tester, shell(), size: const Size(390, 844), dark: true);
    await tester.tap(find.byTooltip('Folders'));
    await settle(tester);
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('Sent')),
    );
    await settle(tester);
    await tester.tap(find.text('Trip to Lisbon'));
    await shoot(tester, 'phone_read_receipt_dark');
  });

  // Follow-up reminders: sent mail back with "No reply yet" at the top of
  // the inbox, "Remind me if no reply" on a sent email and in compose,
  // and the "Waiting for a reply" list.
  testWidgets('follow-ups', (tester) async {
    _seedDemo(app.store);
    _seedFollowUps(app.store);
    await show(tester, shell(), size: const Size(1440, 900));
    await shoot(tester, 'desktop_follow_ups_inbox');
    await tester.tap(find.text('Waiting for a reply'));
    await settle(tester);
    await tester.tap(find.text('Notes from Tuesday'));
    await shoot(tester, 'desktop_follow_ups_list');
    await tester.tap(find.byTooltip('Change reminder'));
    await shoot(tester, 'desktop_follow_ups_sheet');
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);

    await tester.pumpWidget(const SizedBox()); // a fresh start
    await show(tester, shell(), size: const Size(390, 844));
    await shoot(tester, 'phone_follow_ups_inbox');
    await tester.tap(find.byTooltip('Folders'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Waiting for a reply'),
      ),
    );
    await shoot(tester, 'phone_follow_ups_list');
    await tester.tap(find.byTooltip('New message (C)'));
    await settle(tester);
    await tester.tap(find.byTooltip('Remind me if no reply'));
    await shoot(tester, 'phone_follow_ups_compose');
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    await tester.pump(const Duration(seconds: 3)); // the draft's autosave

    await tester.pumpWidget(const SizedBox());
    await show(tester, shell(), size: const Size(390, 844), dark: true);
    await tester.tap(find.byTooltip('Folders'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Waiting for a reply'),
      ),
    );
    await shoot(tester, 'phone_follow_ups_list_dark');
  });

  // New since you were away: the app closed last night, opened this
  // morning. Its messages are only in that section until Done.
  for (final (name, size, dark) in [
    ('phone', const Size(390, 844), false),
    ('desktop', const Size(1440, 900), false),
    ('desktop_dark', const Size(1440, 900), true),
  ]) {
    testWidgets('new since away $name', (tester) async {
      // Not the demo inbox: its mail of a few minutes ago would count as
      // known senders for the Screener.
      final now = DateTime.now();
      final left = now.subtract(const Duration(hours: 14));
      seedAwayMail(app.store, left: left.toUtc(), back: now.toUtc());
      NewSinceAway(app.store).wentAway(left);
      await show(tester, shell(), size: size, dark: dark);
      await shoot(tester, 'new_since_away_$name');
      if (name != 'phone') return;
      await tester.tap(find.widgetWithText(TextButton, 'Done'));
      await shoot(tester, 'new_since_away_${name}_done');

      await tester.pumpWidget(const SizedBox());
      await show(
        tester,
        SettingsPage(
          services: app.services,
          controller: MailController(app.services),
          isAndroid: true,
        ),
        size: size,
      );
      // The Inbox & sorting group.
      await tester.tap(find.text('Inbox & sorting'));
      await settle(tester);
      await shoot(tester, 'new_since_away_${name}_setting');
    });
  }

  // Learn from my corrections: GitHub notifications marked "Not a
  // subscription", and one like them from Codeberg left out; the
  // settings under Advanced.
  for (final (name, size) in [
    ('phone', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
  ]) {
    testWidgets('learning $name', (tester) async {
      _seedSubscriptions(app.store);
      _seedLearning(app.store);
      await show(
        tester,
        SubscriptionsPage(controller: MailController(app.services)),
        size: size,
      );
      await tester.scrollUntilVisible(
        find.textContaining('marked "not a subscription"'),
        300,
      );
      await tester.tap(find.textContaining('marked "not a subscription"'));
      await settle(tester);
      await tester.scrollUntilVisible(find.text('Jonas W'), 300);
      await shoot(tester, '${name}_learning_hidden');
      await show(
        tester,
        AdvancedSettingsPage(services: app.services),
        size: size,
      );
      await shoot(tester, '${name}_learning_settings');
    });
  }

  // Writing help ("Write with AI", with a stand-in AI provider): a reply
  // with the button, the sheet's choices, a drafted reply in the preview,
  // and the body after Replace with its Undo note.
  group('writing help', () {
    late FakeAiProvider fake;
    setUp(() async {
      await app.dispose();
      fake = FakeAiProvider();
      app = await TestApp.create(aiProviders: (_) => fake);
      await app.services.ai.saveProvider(
        AiProviderKind.claude,
        key: 'demo-key',
        model: 'demo-model',
      );
      app.services.ai.setOn(AiFeatures.writing.id, true);
      app.services.ai.features.confirm(
        AiFeatures.writing.id,
        AiProviderKind.claude,
        'Anthropic',
      );
    });

    for (final (size, name) in [
      (const Size(1440, 900), 'desktop'),
      (const Size(390, 844), 'phone'),
    ]) {
      testWidgets('writing help $name', (tester) async {
        fake.replies.add(
          const FakeAiReply(
            'Hi Priya,\n\nThursday at 10 works for me. I\'ll bring the '
            'printed drafts so we can go through them together.\n\n'
            'See you then!',
          ),
        );
        final alice = app.store.accounts.all().single;
        final controller = ComposeController(
          app.services,
          Draft(
            accountId: alice.id,
            to: const [
              MailAddress(
                displayName: 'Priya Shah',
                localPart: 'priya',
                domain: 'studio.example',
              ),
            ],
            subject: 'Re: Notes from Tuesday',
            inReplyTo: 'notes-1@studio.example',
            quote:
                'On Tue, 10 Nov 2026 at 16:40, Priya Shah '
                '<priya@studio.example> wrote:\n> Could we meet on Thursday '
                'at 10 instead? Bring the printed drafts if you can.\n>\n> '
                'Priya',
          ),
        );
        addTearDown(controller.dispose);
        await show(tester, ComposePage(controller: controller), size: size);
        await shoot(tester, '${name}_writing_compose');
        await tester.tap(find.byKey(const ValueKey('compose-write-with-ai')));
        await settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('writing-note')),
          'yes, and I\'ll bring the drafts',
        );
        await shoot(tester, '${name}_writing_sheet');
        await tester.tap(find.byKey(const ValueKey('writing-draft')));
        await shoot(tester, '${name}_writing_preview');
        await tester.tap(find.byKey(const ValueKey('writing-replace')));
        await shoot(tester, '${name}_writing_replaced');
        // Let the draft's save timer run out.
        await tester.pump(const Duration(seconds: 3));
      });
    }
  });
}

/// Notifications about billing code: GitHub's marked "Not a
/// subscription" (and learned from), and one like them from Codeberg.
void _seedLearning(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now().toUtc();
  const footer =
      '\n\nReply to this email directly, view it on GitHub, or '
      'unsubscribe. You are receiving this because you were mentioned.';
  final notifications = [
    (
      'github.com',
      'Mei Chen',
      '[acme/payments] Invoice PDF is missing the tax line (#311)',
      'The invoice PDF generated for annual subscriptions drops the GST '
          'line.$footer',
    ),
    (
      'github.com',
      'Rahul K',
      '[acme/payments] Receipt emails sent twice after renewal (#318)',
      'After a subscription renewal the receipt job runs twice.$footer',
    ),
    (
      'codeberg.org',
      'Jonas W',
      '[acme/infra] Invoice export job times out (#57)',
      'The nightly invoice export for subscriptions times out after 30 '
          'minutes.\n\nReply to this email directly or view it on '
          'Codeberg. You are receiving this because you were mentioned.',
    ),
  ];
  store.messages.upsertSummaries(inbox.id, [
    for (final (i, (domain, name, subject, text)) in notifications.indexed)
      MessageSummary(
        uid: 700 + i,
        receivedAt: now.subtract(Duration(days: 6 + 9 * i)),
        subject: subject,
        from: MailAddress(
          displayName: name,
          localPart: 'notifications',
          domain: domain,
        ),
        snippet: text,
        flags: MessageFlags.fromImap([r'\Seen']),
      ),
  ]);
  store.settings.write('subscriptions.hidden', 'github.com');
  Corrections(store).rejected(MailKind.subscription, [
    for (final (domain, name, subject, text) in notifications)
      if (domain == 'github.com')
        MailSample(
          address: 'notifications@$domain',
          domain: domain,
          senderName: name,
          subject: subject,
          text: text,
        ),
  ]);
}

/// Four emails Alex sent: two came back with "No reply yet", two are
/// waiting.
/// Two sent emails that asked for read receipts, and the receipts that
/// came back (one saying it was deleted unread: not shown).
void _seedReadReceipts(MailStore store) {
  final accountId = store.accounts.all().single.id;
  final sent = store.mailboxes.bySpecialUse(accountId, SpecialUse.sent)!;
  final now = DateTime.now().toUtc();
  MailAddress who(String address, [String? name]) => MailAddress(
    localPart: address.substring(0, address.indexOf('@')),
    domain: address.substring(address.indexOf('@') + 1),
    displayName: name,
  );
  final me = who('alice@citusmail.test', 'Alex Morgan');
  for (final (uid, id, subject, to, body, ago) in [
    (
      801,
      'plans-1@demo.example',
      'Quarterly plans',
      [
        who('ana@northwind.example', 'Ana Silva'),
        who('ben@contoso.example', 'Ben Okafor'),
        who('chloe@fastmail.example', 'Chloe Martin'),
      ],
      'Hi all,\n\nHere are the plans for the next quarter. Could you each '
          'have a look before Thursday\'s meeting?\n\nThanks,\nAlex',
      const Duration(hours: 5),
    ),
    (
      802,
      'trip-2@demo.example',
      'Trip to Lisbon',
      [who('dev@mobile.example', 'Dev Patel')],
      'Hi Dev,\n\nThe tickets are booked: we fly out on the 14th at 9:40. '
          'The hotel is two streets from the river.\n\nAlex',
      const Duration(days: 1, hours: 3),
    ),
  ]) {
    final at = now.subtract(ago);
    store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: uid,
        receivedAt: at,
        sentAt: at,
        subject: subject,
        messageId: id,
        from: me,
        to: to,
        snippet: body.replaceAll('\n', ' '),
        flags: MessageFlags.fromImap([r'\Seen']),
        headers: const {
          'disposition-notification-to': ['<alice@citusmail.test>'],
        },
      ),
    ]);
    final raw =
        'From: Alex Morgan <alice@citusmail.test>\r\n'
        'To: ${to.map((a) => '${a.displayName} <${a.address}>').join(', ')}\r\n'
        'Subject: $subject\r\n'
        'Message-ID: <$id>\r\n'
        'Disposition-Notification-To: <alice@citusmail.test>\r\n'
        'Content-Type: text/plain; charset=utf-8\r\n\r\n'
        '${body.replaceAll('\n', '\r\n')}\r\n';
    store.messages.saveBody(
      store.messages.byUid(sent.id, uid)!.id,
      Uint8List.fromList(raw.codeUnits),
      searchableText: body,
    );
    store.receipts.requested(accountId, id);
  }
  for (final (id, reader, kind, ago) in [
    ('plans-1@demo.example', 'ana@northwind.example', 'displayed', 4),
    ('plans-1@demo.example', 'ben@contoso.example', 'displayed', 2),
    ('plans-1@demo.example', 'chloe@fastmail.example', 'deleted', 1),
    ('trip-2@demo.example', 'dev@mobile.example', 'displayed', 20),
  ]) {
    store.receipts.record(
      accountId,
      id,
      recipient: reader,
      disposition: kind,
      at: now.subtract(Duration(hours: ago, minutes: 18)),
    );
  }
}

void _seedFollowUps(MailStore store) {
  final accountId = store.accounts.all().single.id;
  final sent = store.mailboxes.bySpecialUse(accountId, SpecialUse.sent)!;
  final me = store.accounts.byId(accountId)!.email;
  final now = DateTime.now();
  MailAddress who(String address, [String? name]) => MailAddress(
    localPart: address.substring(0, address.indexOf('@')),
    domain: address.substring(address.indexOf('@') + 1),
    displayName: name,
  );
  var uid = 700;
  MessageSummary mail(
    Duration ago,
    List<MailAddress> to,
    String subject,
    String snippet,
  ) => MessageSummary(
    uid: uid++,
    receivedAt: now.toUtc().subtract(ago),
    sentAt: now.toUtc().subtract(ago),
    subject: subject,
    from: who(me, 'Alex Morgan'),
    to: to,
    snippet: snippet,
    messageId: 'followup$uid@demo.example',
    flags: MessageFlags.fromImap([r'\Seen']),
  );
  store.messages.upsertSummaries(sent.id, [
    mail(
      const Duration(days: 3, hours: 2),
      [who('ana@buildright.example', 'Ana Costa')],
      'Quote for the kitchen',
      'Hi Ana, could you send the quote for the kitchen by Friday?',
    ),
    mail(
      const Duration(days: 7, hours: 1),
      [
        who('accounts@lakeside-dental.example', 'Lakeside Dental'),
        who('billing@lakeside-dental.example'),
      ],
      'Refund for the cancelled appointment',
      'Hello, I was charged for the appointment I cancelled on the 2nd.',
    ),
    mail(
      const Duration(days: 1, hours: 4),
      [who('priya@studio.example', 'Priya Shah')],
      'Notes from Tuesday',
      'Here are my notes from Tuesday. Talk Monday!',
    ),
    mail(
      const Duration(hours: 5),
      [
        who('ben@reunion.example', 'Ben Okafor'),
        who('chloe@reunion.example', 'Chloe Martin'),
        who('dev@reunion.example', 'Dev Patel'),
      ],
      'Venue for the reunion',
      'Which of the three places do you like best?',
    ),
  ]);
  final followUps = FollowUpReminders(store);
  StoredMessage m(int uid) => store.messages.byUid(sent.id, uid)!;
  followUps
    ..remind(
      followUps.forMessage(m(700), now.subtract(const Duration(hours: 2))),
    )
    ..remind(
      followUps.forMessage(m(701), now.subtract(const Duration(days: 2))),
    )
    ..remind(
      followUps.forMessage(
        m(702),
        DateTime(now.year, now.month, now.day + 2, 9),
      ),
    )
    ..remind(
      followUps.forMessage(
        m(703),
        DateTime(now.year, now.month, now.day + 7, 18),
      ),
    )
    ..check(now: now);
  followUps.claimUnnotified();
}

/// Two messages scheduled with Send later, and one that failed.
void _seedScheduledSends(MailStore store, Sender sender, DateTime now) {
  final accountId = store.accounts.all().single.id;
  MailAddress a(String address, String name) => MailAddress(
    displayName: name,
    localPart: address.split('@').first,
    domain: address.split('@').last,
  );
  sender.schedule(
    Draft(
      accountId: accountId,
      to: [a('maria@studio.example', 'Maria Lopez')],
      subject: 'Contract: my comments on clause 4',
      body: 'Hi Maria,\n\nMy comments are below.',
    ),
    DateTime(2026, 11, 5, 8),
    now: now,
  );
  sender.schedule(
    Draft(
      accountId: accountId,
      to: [a('team@studio.example', 'Studio team')],
      subject: 'Weekly plan',
      body: 'Good morning all,\n\nHere is the plan for the week.',
    ),
    DateTime(2026, 11, 9, 8),
    now: now,
  );
  sender.schedule(
    Draft(
      accountId: accountId,
      to: [a('tom@old-domain.example', 'Tom Baker')],
      subject: 'Birthday surprise',
      body: 'Shh!',
    ),
    DateTime(2026, 11, 4, 8),
    now: now.subtract(const Duration(days: 1)),
  );
  final failed = store.outbox.sends().last;
  store.outbox.markFailed(
    failed.id,
    '550 5.1.1 tom@old-domain.example: mailbox unavailable',
  );
}

/// Three snoozed emails, and one back from snooze a moment ago.
void _seedSnoozes(MailStore store) {
  final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
  final now = DateTime.now();
  MailAddress who(String address, String name) => MailAddress(
    localPart: address.substring(0, address.indexOf('@')),
    domain: address.substring(address.indexOf('@') + 1),
    displayName: name,
  );
  var uid = 500;
  MessageSummary mail(
    int daysAgo,
    MailAddress from,
    String subject,
    String snippet, {
    bool seen = true,
  }) => MessageSummary(
    uid: uid++,
    receivedAt: now.toUtc().subtract(Duration(days: daysAgo, hours: 3)),
    subject: subject,
    from: from,
    snippet: snippet,
    messageId: 'snooze$uid@demo.example',
    flags: MessageFlags.fromImap([if (seen) r'\Seen']),
  );
  store.messages.upsertSummaries(inbox.id, [
    mail(
      3,
      who('maria.lopez@studio-north.example', 'Maria Lopez'),
      'Draft contract for review',
      'Could you look at clause 4 before Friday? The rest is as we agreed.',
    ),
    mail(
      2,
      who('tom@harbour-sailing.example', 'Tom Baker'),
      'Boat trip in the spring?',
      'We are planning a few days on the water in April. Would you be up '
          'for it?',
    ),
    mail(
      5,
      who('bookings@lakeside-dental.example', 'Lakeside Dental'),
      'Time for your check-up',
      'It has been six months since your last visit. Book a time online.',
    ),
    mail(
      6,
      who('j.chen@fieldwork.example', 'Jun Chen'),
      'Quarterly figures for the board',
      'Attached are the numbers we talked about. Let me know if anything '
          'looks off before Thursday.',
      seen: false,
    ),
  ]);
  DateTime on(int days, int hour) =>
      DateTime(now.year, now.month, now.day + days, hour);
  store.snoozes.snooze('snooze501@demo.example', on(1, 8));
  store.snoozes.snooze('snooze502@demo.example', on(5, 9));
  store.snoozes.snooze('snooze503@demo.example', on(9, 8));
  // Came back a few minutes ago.
  store.snoozes.snooze(
    'snooze504@demo.example',
    now.subtract(const Duration(minutes: 4)),
  );
  store.snoozes.wake();
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

/// A second account with a long address and some unread mail.
void _seedSecondAccount(MailStore store) {
  final account = store.accounts.add(
    NewAccount(
      email: 'robert.household-accounts@citusmail.test',
      username: 'robert.household-accounts@citusmail.test',
      imap: ServerSettings(
        host: 'mail.citusmail.test',
        port: 993,
        security: ConnectionSecurity.implicitTls,
      ),
      smtp: ServerSettings(
        host: 'mail.citusmail.test',
        port: 465,
        security: ConnectionSecurity.implicitTls,
      ),
    ),
  );
  final boxes = store.mailboxes.replaceAll(account.id, [
    ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: const {}),
    ImapMailboxInfo(
      encodedName: 'Sent',
      delimiter: '/',
      attributes: const {r'\Sent'},
    ),
    ImapMailboxInfo(
      encodedName: 'Trash',
      delimiter: '/',
      attributes: const {r'\Trash'},
    ),
  ]);
  final inbox = boxes.firstWhere((b) => b.isInbox);
  final now = DateTime.now().toUtc();
  store.messages.upsertSummaries(inbox.id, [
    for (var i = 0; i < 33; i++)
      MessageSummary(
        uid: 900 + i,
        receivedAt: now.subtract(Duration(hours: 3 + i * 7)),
        subject: 'Household note ${i + 1}',
        from: MailAddress(
          localPart: 'school',
          domain: 'district.example',
          displayName: 'School District',
        ),
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
/// A scanner that "reads" [text] as soon as it shows.
final class _AutoScan extends StatefulWidget {
  const _AutoScan({required this.text, required this.onCode});

  final String text;
  final ValueChanged<String> onCode;

  @override
  State<_AutoScan> createState() => _AutoScanState();
}

final class _AutoScanState extends State<_AutoScan> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onCode(widget.text),
    );
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Made-up account mail for the "Online accounts" screen.
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

/// Paints [object] and everything below it again (after a paint setting
/// changed).
void _repaint(RenderObject object) {
  object.markNeedsPaint();
  object.visitChildren(_repaint);
}
