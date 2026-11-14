// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/summaries.dart';
import 'package:citusmail/src/services/ai_assistant.dart';
import 'package:citusmail/src/ui/ai_settings_page.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/settings_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_ai/testing.dart';

import 'support/test_app.dart';

/// Settings, "AI assistant (your own key)", with a fake provider: never a
/// real one.
void main() {
  late TestApp app;
  late FakeAiProvider fake;
  late List<AiProviderConfig> made;

  setUp(() async {
    made = [];
    fake = FakeAiProvider(
      models: const [
        AiModel('claude-haiku-5-5'),
        AiModel('claude-opus-5-5'),
        AiModel('claude-sonnet-5-5'),
      ],
    );
    app = await TestApp.create(
      aiProviders: (config) {
        made.add(config);
        return fake;
      },
    );
  });
  tearDown(() => app.dispose());

  AiAssistant ai() => app.services.ai;

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(900, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        home: AiSettingsPage(ai: ai(), summaries: app.services.summaries),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> addClaude(WidgetTester tester, String key) async {
    await tapKey(tester, 'ai-add-provider');
    await tester.enterText(find.byKey(const ValueKey('ai-key')), key);
    await tapKey(tester, 'ai-test-key');
  }

  testWidgets('nothing set up: everything off, and says what it would do', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Add your key'), findsOneWidget);
    expect(find.textContaining('Nothing reaches us'), findsOneWidget);
    expect(find.textContaining('Your keys stay in this device'), findsOne);
    final summaries = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('ai-feature-summaries')),
    );
    expect(summaries.value, isFalse);
    expect(summaries.onChanged, isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-feature-summaries')),
        matching: find.text('Add a provider and key first, above.'),
      ),
      findsOneWidget,
    );
    expect(find.text('Nothing used this month.'), findsOneWidget);
    expect(find.text('No limit'), findsOneWidget);
    expect(made, isEmpty);
  });

  testWidgets('add Claude: test the key, pick a model, key in the keychain', (
    tester,
  ) async {
    await show(tester);
    await tapKey(tester, 'ai-add-provider');
    // Saved only once the key worked.
    FilledButton save() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('ai-save-provider')),
    );
    expect(save().onPressed, isNull);
    await tapKey(tester, 'ai-test-key');
    expect(find.text('Paste your Anthropic API key first.'), findsOneWidget);
    expect(made, isEmpty);

    // The key is hidden while typed.
    final field = find.byKey(const ValueKey('ai-key'));
    await tester.enterText(field, '  sk-ant-api03-secret-9f3c  ');
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .obscureText,
      isTrue,
    );
    await tapKey(tester, 'ai-test-key');
    expect(made.single.kind, AiProviderKind.claude);
    expect(made.single.apiKey, 'sk-ant-api03-secret-9f3c');
    expect(find.text('The key works: 3 models.'), findsOneWidget);
    final menu = tester.widget<DropdownMenu<String>>(
      find.byKey(const ValueKey('ai-model')),
    );
    expect(menu.controller!.text, 'claude-opus-5-5');
    expect(save().onPressed, isNotNull);
    await tapKey(tester, 'ai-save-provider');

    // The key went to the keychain, never into the settings.
    expect(
      await app.services.secrets.read(
        AiAssistant.keychainKey(AiProviderKind.claude),
      ),
      'sk-ant-api03-secret-9f3c',
    );
    for (final name in ['ai.providers', 'ai.default']) {
      expect(app.store.settings.read(name), isNot(contains('secret')));
    }
    expect(
      ai().features.defaultChoice,
      const AiChoice(AiProviderKind.claude, 'claude-opus-5-5'),
    );
    // Only the end of the key shows.
    expect(find.text('Key ••••9f3c'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    expect(find.text('Claude (Anthropic), claude-opus-5-5'), findsOneWidget);

    // Now the feature can be turned on; nothing was sent but the test.
    await tapKey(tester, 'ai-feature-summaries');
    expect(ai().isOn(AiFeatures.summaries.id), isTrue);
    expect(fake.requests, isEmpty);
  });

  testWidgets('a key the provider refuses is said plainly and not saved', (
    tester,
  ) async {
    fake.listModelsError = const AiException(AiProblem.badKey, 'invalid');
    await show(tester);
    await addClaude(tester, 'sk-wrong');
    expect(
      find.text(
        'Anthropic didn\'t accept the key. Check it in Settings, AI assistant.',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('ai-save-provider')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(ai().providerSettings.configured, isEmpty);
    expect(
      await app.services.secrets.read(
        AiAssistant.keychainKey(AiProviderKind.claude),
      ),
      isNull,
    );
  });

  testWidgets('a model on your own computer: address, no key', (tester) async {
    await show(tester);
    await tapKey(tester, 'ai-add-provider');
    await tester.tap(find.byKey(const ValueKey('ai-provider-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom (OpenAI-compatible)').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'ai-test-key');
    expect(find.textContaining('Enter the endpoint\'s address'), findsOne);
    await tester.enterText(
      find.byKey(const ValueKey('ai-address')),
      'http://localhost:11434/v1',
    );
    await tapKey(tester, 'ai-test-key');
    expect(made.single.kind, AiProviderKind.custom);
    expect(made.single.baseUrl, Uri.parse('http://localhost:11434/v1'));
    expect(made.single.apiKey, isEmpty);
    await tapKey(tester, 'ai-save-provider');
    expect(find.text('http://localhost:11434/v1\nNo key'), findsOneWidget);
    expect(ai().features.defaultChoice?.provider, AiProviderKind.custom);
  });

  testWidgets('remove a provider: its key goes, features stop', (tester) async {
    await ai().saveProvider(
      AiProviderKind.claude,
      key: 'sk-ant-1234567890',
      model: 'claude-opus-5-5',
    );
    ai().setOn(AiFeatures.summaries.id, true);
    await show(tester);
    expect(find.text('Key ••••7890'), findsOneWidget);
    await tapKey(tester, 'ai-remove-claude');
    await tapKey(tester, 'ai-remove-confirm');
    expect(ai().providerSettings.configured, isEmpty);
    expect(ai().features.defaultChoice, isNull);
    expect(ai().isOn(AiFeatures.summaries.id), isFalse);
    expect(
      await app.services.secrets.read(
        AiAssistant.keychainKey(AiProviderKind.claude),
      ),
      isNull,
    );
    expect(find.text('Add your key'), findsOneWidget);
  });

  testWidgets('choose another default model from the key\'s list', (
    tester,
  ) async {
    await ai().saveProvider(
      AiProviderKind.claude,
      key: 'sk-ant-1234567890',
      model: 'claude-opus-5-5',
    );
    await show(tester);
    await tapKey(tester, 'ai-default-model');
    await tester.tap(find.byKey(const ValueKey('ai-default-model-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('claude-haiku-5-5').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'ai-default-save');
    expect(
      ai().features.defaultChoice,
      const AiChoice(AiProviderKind.claude, 'claude-haiku-5-5'),
    );
    expect(find.text('Claude (Anthropic), claude-haiku-5-5'), findsOneWidget);
  });

  testWidgets('this month\'s use, the monthly limit and prices', (
    tester,
  ) async {
    await ai().saveProvider(
      AiProviderKind.claude,
      key: 'sk-ant-1234567890',
      model: 'claude-opus-5-5',
    );
    ai().ledger
      ..record(
        AiProviderKind.claude,
        'claude-opus-5-5',
        const AiUsage(inputTokens: 200000, outputTokens: 10000),
      )
      ..record(
        AiProviderKind.custom,
        'llama3.2',
        const AiUsage(inputTokens: 1000, outputTokens: 100),
      );
    await show(tester);
    // $4 x 0.2 + $20 x 0.01 = $1.00.
    expect(find.text('This month: \$1.00 for 2 requests.'), findsOneWidget);
    expect(
      find.text(
        'Anthropic, claude-opus-5-5: 1 request, 200,000 tokens sent, '
        '10,000 received, \$1.00',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('llama3.2: 1 request'), findsOneWidget);
    expect(find.textContaining('price unknown'), findsOneWidget);
    expect(find.textContaining('Models without a price'), findsOneWidget);

    // A limit, reached at once.
    await tapKey(tester, 'ai-cap');
    await tester.enterText(find.byKey(const ValueKey('ai-number-0')), '1');
    await tapKey(tester, 'ai-number-save');
    expect(ai().ledger.monthlyCap, 1);
    expect(find.textContaining('\$1.00 a month: reached'), findsOneWidget);
    // And none again.
    await tapKey(tester, 'ai-cap');
    await tester.enterText(find.byKey(const ValueKey('ai-number-0')), '');
    await tapKey(tester, 'ai-number-save');
    expect(ai().ledger.monthlyCap, isNull);
    expect(find.text('No limit'), findsOneWidget);

    // Prices: Anthropic's filled in; the local model's set by hand.
    await tapKey(tester, 'ai-prices');
    expect(find.text('Claude (Anthropic): \$4 / \$20'), findsOneWidget);
    expect(find.text('Claude (Anthropic): \$0.1 / \$0.5'), findsOneWidget);
    expect(find.text('Custom (OpenAI-compatible): unknown'), findsOneWidget);
    await tapKey(tester, 'ai-price-custom/llama3.2');
    await tester.enterText(find.byKey(const ValueKey('ai-number-0')), 'free');
    await tapKey(tester, 'ai-number-save');
    expect(find.text('Enter an amount such as 5 or 0.25.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ai-number-0')), '0,5');
    await tester.enterText(find.byKey(const ValueKey('ai-number-1')), '1');
    await tapKey(tester, 'ai-number-save');
    expect(
      ai().prices.price(AiProviderKind.custom, 'llama3.2'),
      const AiPrice(0.5, 1),
    );
    expect(
      find.text('Custom (OpenAI-compatible): \$0.5 / \$1 (yours)'),
      findsOneWidget,
    );
    // Reset goes back to unknown.
    await tapKey(tester, 'ai-price-custom/llama3.2');
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(ai().prices.price(AiProviderKind.custom, 'llama3.2'), isNull);
  });

  testWidgets('saved summaries can be forgotten', (tester) async {
    await ai().saveProvider(
      AiProviderKind.claude,
      key: 'sk-ant-1234567890',
      model: 'claude-opus-5-5',
    );
    ai().setOn(AiFeatures.summaries.id, true);
    final provider = await ai().providerFor(AiFeatures.summaries.id);
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    final message = app.store.messages.byUid(inbox.id, 1)!;
    await tester.runAsync(
      () => app.services.summaries
          .summarise(provider!, message, SummaryScope.message)
          .drain<void>(),
    );
    expect(app.services.summaries.savedCount, 1);
    await show(tester);
    expect(
      find.text('1 kept on this device, so they aren\'t sent again'),
      findsOne,
    );
    await tapKey(tester, 'ai-forget-summaries');
    expect(app.services.summaries.savedCount, 0);
    expect(find.byKey(const ValueKey('ai-forget-summaries')), findsNothing);
  });

  test('settings search finds it by the words people use', () {
    List<String> ids(String query) => [
      for (final e in SettingsCatalog.search(query, android: false)) e.id,
    ];
    for (final words in [
      'ai',
      'gpt',
      'claude',
      'llama',
      'openai',
      'anthropic',
      'api key',
    ]) {
      expect(ids(words), contains('aiAssistant'), reason: words);
    }
    expect(ids('summarise'), contains('ai-summaries'));
    expect(ids('spending limit'), contains('aiLimit'));
    for (final e in SettingsCatalog.entries.where(
      (e) => e.id.startsWith('ai'),
    )) {
      expect(e.section, 'ai', reason: e.id);
    }
  });

  testWidgets('fits a phone', (tester) async {
    await ai().saveProvider(
      AiProviderKind.claude,
      key: 'sk-ant-1234567890',
      model: 'claude-opus-5-5',
    );
    await show(tester, size: const Size(360, 740));
    await tapKey(tester, 'ai-add-provider');
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'sk-x');
    await tapKey(tester, 'ai-test-key');
    expect(tester.takeException(), isNull);
  });
}
