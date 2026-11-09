// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// WCAG contrast ratio of two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('tokens', () {
    for (final (name, theme) in [
      ('light', CitusmailTheme.light()),
      ('dark', CitusmailTheme.dark()),
    ]) {
      final colors = theme.colorScheme;

      test('$name: cards are flat, rounded 12, with a hairline', () {
        final card = theme.cardTheme;
        expect(card.elevation, 0);
        final shape = card.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(12));
        expect(shape.side.color, colors.outlineVariant);
        expect(shape.side.width, 1);
      });

      test('$name: text meets AA on every surface it sits on', () {
        for (final surface in [
          colors.surface,
          colors.surfaceContainerLow,
          colors.surfaceContainer,
          theme.cardTheme.color!,
        ]) {
          expect(contrast(colors.onSurface, surface), greaterThan(4.5));
          expect(contrast(colors.onSurfaceVariant, surface), greaterThan(4.5));
        }
        // Lagoon text (links, text buttons) sits on the page and the list,
        // not on field fills.
        for (final surface in [
          colors.surface,
          colors.surfaceContainerLow,
          theme.cardTheme.color!,
        ]) {
          expect(contrast(colors.primary, surface), greaterThan(4.5));
        }
        expect(
          contrast(colors.onPrimaryContainer, colors.primaryContainer),
          greaterThan(4.5),
        );
      });

      test('$name: the open row is tinted and barred in lagoon', () {
        final list = theme.extension<ListColors>()!;
        expect(list.selected, colors.primaryContainer);
        expect(list.indicator, colors.primary);
      });

      test('$name: hover is visible', () {
        expect(theme.hoverColor.a, closeTo(0.06, 0.001));
      });
    }

    test('dark cards sit above the page, not below it', () {
      final theme = CitusmailTheme.dark();
      expect(
        theme.cardTheme.color!.computeLuminance(),
        greaterThan(theme.scaffoldBackgroundColor.computeLuminance()),
      );
    });

    test('desktop pages fade forward; phones keep their own transitions', () {
      final builders = CitusmailTheme.light().pageTransitionsTheme.builders;
      expect(
        builders[TargetPlatform.linux],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.windows],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.android],
        const PageTransitionsTheme().builders[TargetPlatform.android],
      );
    });
  });

  group('list rows', () {
    late TestApp app;

    setUp(() async => app = await TestApp.create());
    tearDown(() => app.dispose());

    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: MailShell(
            notifications: false,
            services: app.services,
            onAddAccount: () {},
            onAccountsChanged: () {},
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    TextStyle styleOf(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text).first).style!;

    testWidgets('unread: subject semibold in ink; read: regular and muted', (
      tester,
    ) async {
      await show(tester);
      final colors = CitusmailTheme.light().colorScheme;
      // "Hello there" is unread, "Keep this" (pinned) has been read.
      final unread = styleOf(tester, 'Hello there');
      expect(unread.fontWeight, FontWeight.w600);
      expect(unread.color, colors.onSurface);
      final read = styleOf(tester, 'Keep this');
      expect(read.fontWeight, FontWeight.w400);
      expect(read.color, colors.onSurfaceVariant);
      expect(
        styleOf(tester, 'Visible body text.').fontSize,
        MessageTile.previewSize,
      );
    });

    testWidgets('the open row carries a bar at its left', (tester) async {
      await show(tester);
      expect(find.byKey(const ValueKey('open-row-bar')), findsNothing);
      await tester.tap(find.text('Hello there'));
      await tester.pump();
      expect(find.byKey(const ValueKey('open-row-bar')), findsOneWidget);
    });
  });
}
