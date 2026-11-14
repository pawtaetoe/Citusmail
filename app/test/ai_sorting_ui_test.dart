// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// "Sorting backup" on screen: its setting asks before anything is sent,
// and the reader says who sorted an email and why, with "Not right?".

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:citusmail/src/services/ai_sorter.dart';
import 'package:citusmail/src/ui/ai_feature_tiles.dart';
import 'package:citusmail/src/ui/ai_sort_notice.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/features.dart';
import 'package:citusmail/src/ui/settings_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_ai/testing.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;

  setUp(() async {
    app = await TestApp.create(aiProviders: (_) => FakeAiProvider());
  });
  tearDown(() => app.dispose());

  Future<void> addProvider() => app.services.ai.saveProvider(
    AiProviderKind.claude,
    key: 'test-key',
    model: 'fake-small',
  );

  Future<void> show(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: Scaffold(body: ListView(children: [child])),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool confirmed() => app.services.ai.features.confirmed(
    AiFeatures.sorting.id,
    AiProviderKind.claude,
    'Anthropic',
  );

  group('the setting', () {
    Widget tile() => aiFeatureTiles[AiFeatures.sorting.id]!(app.services.ai);

    testWidgets('off by default, and only with a provider', (tester) async {
      await show(tester, tile());
      final off = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('ai-feature-sorting')),
      );
      expect(off.value, isFalse);
      expect(off.onChanged, isNull);
      expect(find.text('Add a provider and key first, above.'), findsOneWidget);
      expect(app.services.ai.isOn(AiSorter.featureId), isFalse);
    });

    testWidgets('turning it on asks first; "Not now" leaves it off', (
      tester,
    ) async {
      await addProvider();
      await show(tester, tile());
      await tester.tap(find.byKey(const ValueKey('ai-feature-sorting')));
      await tester.pumpAndSettle();
      expect(find.text('Send new mail to Anthropic?'), findsOneWidget);
      expect(find.textContaining('the first 1,500 characters'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(app.services.ai.isOn(AiSorter.featureId), isFalse);
      expect(confirmed(), isFalse);

      await tester.tap(find.byKey(const ValueKey('ai-feature-sorting')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-sorting-agree')));
      await tester.pumpAndSettle();
      expect(app.services.ai.isOn(AiSorter.featureId), isTrue);
      expect(confirmed(), isTrue);
      // How many each time, 20 by default.
      expect(find.text('20 emails'), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-sorting-waiting')), findsNothing);
    });

    testWidgets('how many each time, and the last problem', (tester) async {
      await addProvider();
      app.services.ai.setOn(AiSorter.featureId, true);
      (await app.services.ai.providerFor(AiSorter.featureId))!.confirm();
      await show(tester, tile());
      await tester.tap(find.byKey(const ValueKey('ai-sorting-per-sync')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 emails').last);
      await tester.pumpAndSettle();
      expect(app.services.aiSort.perSync, 5);

      app.services.aiSort.problem.value = 'Anthropic says the key is wrong.';
      await tester.pumpAndSettle();
      expect(find.text('Last time, it could not sort'), findsOneWidget);
      expect(find.text('Anthropic says the key is wrong.'), findsOneWidget);
    });

    testWidgets('on, but the provider changed: waits for the user\'s OK', (
      tester,
    ) async {
      await addProvider();
      app.services.ai.setOn(AiSorter.featureId, true);
      await show(tester, tile());
      expect(find.byKey(const ValueKey('ai-sorting-waiting')), findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-sorting-agree')));
      await tester.pumpAndSettle();
      expect(confirmed(), isTrue);
      expect(find.byKey(const ValueKey('ai-sorting-waiting')), findsNothing);
    });

    test('found by search, and listed with the features', () {
      expect(
        SettingsCatalog.search('sorting', android: false).map((e) => e.id),
        contains('ai-sorting'),
      );
      expect(Features.byId('aiSorting'), isNotNull);
    });
  });

  group('the reader', () {
    late MailController controller;
    late StoredMessage hello;

    setUp(() async {
      controller = MailController(app.services);
      await addProvider();
      app.services.ai.setOn(AiSorter.featureId, true);
      final inbox = app.store.mailboxes.inbox(
        app.store.accounts.all().single.id,
      )!;
      hello = app.store.messages.byUid(inbox.id, 1)!;
      // As the sorter leaves it.
      app.store.messages.updateCategories([
        CategoryDecision(
          messageId: hello.id,
          category: MessageCategory.notifications,
          source: CategorySource.rule,
        ),
      ]);
      AiSortLog(app.store).add(
        AiSortEntry(
          messageId: hello.id,
          outcome: AiSortOutcome.applied,
          at: DateTime.now(),
          category: MessageCategory.notifications,
          reason: 'A greeting sent to many people.',
          by: 'Anthropic',
          sender: 'stranger@x.example',
        ),
      );
    });
    tearDown(() => controller.dispose());

    Widget notice() => AiSortNotice(
      controller: controller,
      message: app.store.messages.byId(hello.id)!,
    );

    testWidgets('says who sorted it and why', (tester) async {
      await show(tester, notice());
      expect(
        find.text(
          'Sorted into Notifications by Anthropic because: A greeting sent '
          'to many people.',
        ),
        findsOneWidget,
      );
      expect(find.text('Not right?'), findsOneWidget);
    });

    testWidgets('nothing while the feature is off', (tester) async {
      app.services.ai.setOn(AiSorter.featureId, false);
      await show(tester, notice());
      expect(find.byKey(ValueKey('ai-sort-notice-${hello.id}')), findsNothing);
    });

    testWidgets('nothing on mail the rules sorted', (tester) async {
      AiSortLog(app.store).clear();
      await show(tester, notice());
      expect(find.byKey(ValueKey('ai-sort-notice-${hello.id}')), findsNothing);
    });

    testWidgets('"Not right?" puts it where the user says', (tester) async {
      await show(tester, notice());
      await tester.tap(find.byKey(const ValueKey('ai-sort-not-right')));
      await tester.pumpAndSettle();
      expect(find.text('Put it in Notifications'), findsNothing);
      await tester.tap(find.text('Put it in General'));
      await tester.pumpAndSettle();
      expect(
        app.store.messages.byId(hello.id)!.category,
        MessageCategory.general,
      );
      expect(
        find.text(
          'Moved to General. Mail from stranger@x.example will go there '
          'too.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('ai-sort-notice-${hello.id}')), findsNothing);
      expect(
        SenderSortChoices(app.store).forSender('stranger@x.example'),
        MessageCategory.general,
      );
    });
  });
}
