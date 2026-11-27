// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pages that look through the mail ("Found in your mail", Clean up, the
// Privacy report) slide in at once: their first frame is drawn before
// anything long runs, and the finders run off the UI isolate, so the
// transition is never held up. The page shows its loading state first,
// then what was found.

import 'dart:async';

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/core/widgets/skeleton_rows.dart';
import 'package:citusmail/src/features/accounts/ui/accounts_page.dart';
import 'package:citusmail/src/features/found/ui/appointments_page.dart';
import 'package:citusmail/src/features/found/ui/attachments_page.dart';
import 'package:citusmail/src/features/found/ui/deliveries_page.dart';
import 'package:citusmail/src/features/found/ui/subscriptions_page.dart';
import 'package:citusmail/src/features/found/ui/trips_page.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/inbox/state/message_reads.dart';
import 'package:citusmail/src/features/organise/ui/privacy_report_page.dart';
import 'package:citusmail/src/features/organise/ui/sender_cleanup_page.dart';
import 'package:citusmail/src/services/store_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/appointment_mail.dart';
import 'support/delivery_mail.dart';
import 'support/privacy_mail.dart';
import 'support/test_app.dart';
import 'support/trip_mail.dart';

void main() {
  final pages = <String, Widget Function(MailController c)>{
    'Subscriptions': (c) => SubscriptionsPage(controller: c),
    'Deliveries': (c) => DeliveriesPage(controller: c),
    'Trips': (c) => TripsPage(controller: c),
    'Appointments': (c) => AppointmentsPage(controller: c),
    'Online accounts': (c) => AccountsPage(controller: c),
    'Files': (c) => AttachmentsPage(controller: c),
    'Clean up': (c) => SenderCleanupPage(controller: c),
    'Privacy report': (c) => PrivacyReportPage(services: c.services),
  };

  late TestApp app;
  setUp(() async => app = await TestApp.create(readsInIsolate: true));
  tearDown(() => app.dispose());

  for (final MapEntry(key: name, value: page) in pages.entries) {
    testWidgets('$name: the first frame is drawn at once, then the finds', (
      tester,
    ) async {
      expect(runsInIsolate(app.services.reads), isTrue);
      final now = DateTime.now();
      app.services.settings.autoRead = false;
      seedDeliveries(app.store, now: now);
      seedTrips(app.store, now: now);
      seedAppointments(app.store, now: now);
      seedPrivacyMail(app, now);
      final controller = MailController(app.services);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: CitusmailTheme.light(),
          home: const Scaffold(body: Text('Mail')),
        ),
      );

      final reads = MessageReads.readCount;
      final before = app.store.database.statementCount;
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => page(controller)),
        ),
      );
      // The route's first frame: the page is there, loading.
      await tester.pump();
      final atFirstFrame = app.store.database.statementCount - before;
      // (Built offstage first, for a hero to measure.)
      bool showing(Type type) =>
          find.byType(type, skipOffstage: false).evaluate().isNotEmpty;
      expect(
        showing(SkeletonRows) ||
            showing(CircularProgressIndicator) ||
            showing(LinearProgressIndicator),
        isTrue,
        reason: 'a loading state on the first frame',
      );
      // Only small reads (settings) on the UI's connection so far.
      expect(atFirstFrame, lessThanOrEqualTo(12));
      // The transition goes on while the finds are read elsewhere.
      await tester.pump(const Duration(milliseconds: 100));
      expect(app.store.database.statementCount - before, atFirstFrame);

      // Then what was found fills in.
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.byType(SkeletonRows).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      expect(find.byType(SkeletonRows), findsNothing);
      // No email was read for the page on the UI isolate.
      expect(MessageReads.readCount, reads);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
