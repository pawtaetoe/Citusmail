// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/core/widgets/skeleton_rows.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/ui/message_list_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';

import 'support/test_app.dart';

/// While mail is checked for the first time an empty list shows grey
/// rows on their way, not "No messages here."
void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  testWidgets('the first check shows rows; after it, the empty state', (
    tester,
  ) async {
    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    final searchFocus = FocusNode();
    addTearDown(searchFocus.dispose);
    final account = app.store.accounts.all().single.id;
    final drafts = app.store.mailboxes.bySpecialUse(
      account,
      SpecialUse.drafts,
    )!;

    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Scaffold(
          body: MessageListPane(
            controller: controller,
            onCompose: () {},
            searchFocus: searchFocus,
          ),
        ),
      ),
    );
    controller.goTo(FolderLocation(drafts.id, account));
    controller.status.value = const SyncRunning();
    await tester.pump();
    expect(find.byType(SkeletonRows), findsOneWidget);
    expect(find.bySemanticsLabel('Checking for mail…'), findsOneWidget);
    expect(find.text('No messages here.'), findsNothing);

    // Checked: the folder really is empty.
    controller.status.value = SyncIdle(DateTime.now());
    await tester.pump();
    expect(find.byType(SkeletonRows), findsNothing);
    expect(find.text('No messages here.'), findsOneWidget);

    // A later check doesn't bring the grey rows back.
    controller.status.value = const SyncRunning();
    await tester.pump();
    expect(find.byType(SkeletonRows), findsNothing);
    expect(find.text('No messages here.'), findsOneWidget);
  });

  testWidgets('on a page, in its content column', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: const Scaffold(
          body: SkeletonRows(label: 'Finding deliveries…', maxWidth: 760),
        ),
      ),
    );
    final rows = tester.getRect(find.byKey(const ValueKey('skeleton-rows')));
    expect(rows.width, 760);
    expect(rows.left, (1400 - 760) / 2);
    expect(find.bySemanticsLabel('Finding deliveries…'), findsOneWidget);
  });

  /// The grey rows as painted now.
  Future<List<int>> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .descendant(
            of: find.byType(SkeletonRows),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        return await image.toByteData();
      } finally {
        image.dispose();
      }
    });
    return bytes!.buffer.asUint8List();
  }

  /// The rows while [loaded] is false, then what was loaded.
  Widget rows({bool lessMotion = false, ValueNotifier<bool>? loaded}) =>
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: lessMotion),
            child: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: loaded ?? ValueNotifier(false),
                builder: (context, loaded, _) => loaded
                    ? const Text('Loaded')
                    : const SkeletonRows(label: 'Finding trips…'),
              ),
            ),
          ),
        ),
      );

  testWidgets('a light moves across them while they show', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final loaded = ValueNotifier(false);
    addTearDown(loaded.dispose);
    await tester.pumpWidget(rows(loaded: loaded));
    expect(find.byKey(const ValueKey('skeleton-shimmer')), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
    final before = await pixels(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);
    final later = await pixels(tester);
    expect(later, isNot(equals(before)), reason: 'the light moved');

    // Loaded: the rows go, and nothing keeps moving.
    loaded.value = true;
    await tester.pump();
    expect(find.text('Loaded'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('still when the system asks for less motion', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(rows(lessMotion: true));
    expect(find.byKey(const ValueKey('skeleton-rows')), findsOneWidget);
    expect(find.byKey(const ValueKey('skeleton-shimmer')), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    final before = await pixels(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(await pixels(tester), equals(before));
    // Settles at once, with nothing moving.
    await tester.pumpAndSettle();
  });
}
