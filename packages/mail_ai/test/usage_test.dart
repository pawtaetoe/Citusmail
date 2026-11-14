// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_ai/mail_ai.dart';
import 'package:mail_ai/testing.dart';
import 'package:test/test.dart';

void main() {
  group('prices', () {
    test("Anthropic's are filled in; others unknown until entered", () {
      final prices = AiPriceTable(MemoryAiStore());
      expect(
        prices.price(AiProviderKind.claude, 'claude-opus-5-5'),
        const AiPrice(4, 20),
      );
      expect(
        prices.price(AiProviderKind.claude, 'claude-sonnet-5-5'),
        const AiPrice(2, 10),
      );
      expect(
        prices.price(AiProviderKind.claude, 'claude-haiku-5-5'),
        const AiPrice(0.10, 0.50),
      );
      // A dated id has its alias's price.
      expect(
        prices.price(AiProviderKind.claude, 'claude-haiku-5-5-20261101'),
        const AiPrice(0.10, 0.50),
      );
      expect(prices.price(AiProviderKind.claude, 'claude-opus-5'), isNull);
      expect(prices.price(AiProviderKind.openai, 'gpt-5'), isNull);
      // The same id at another provider is another price.
      expect(prices.price(AiProviderKind.custom, 'claude-opus-5-5'), isNull);
    });

    test('the user can set, clear and reset a price', () {
      final prices = AiPriceTable(MemoryAiStore());
      prices.setPrice(AiProviderKind.openai, 'gpt-5', const AiPrice(1.25, 10));
      expect(
        prices.price(AiProviderKind.openai, 'gpt-5'),
        const AiPrice(1.25, 10),
      );
      expect(prices.isOwn(AiProviderKind.openai, 'gpt-5'), isTrue);
      prices.setPrice(AiProviderKind.claude, 'claude-opus-5-5', null);
      expect(prices.price(AiProviderKind.claude, 'claude-opus-5-5'), isNull);
      prices.reset(AiProviderKind.claude, 'claude-opus-5-5');
      expect(
        prices.price(AiProviderKind.claude, 'claude-opus-5-5'),
        const AiPrice(4, 20),
      );
    });

    test('cost per million tokens', () {
      expect(
        const AiPrice(
          4,
          20,
        ).cost(const AiUsage(inputTokens: 2000, outputTokens: 500)),
        closeTo(0.018, 1e-9),
      );
    });
  });

  group('the ledger', () {
    late MemoryAiStore store;
    var now = DateTime(2026, 11, 14);
    late AiUsageLedger ledger;
    late AiPriceTable prices;
    setUp(() {
      store = MemoryAiStore();
      now = DateTime(2026, 11, 14);
      ledger = AiUsageLedger(store, now: () => now);
      prices = AiPriceTable(store);
    });

    test('adds up tokens per provider and model, per month', () {
      ledger
        ..record(
          AiProviderKind.claude,
          'claude-opus-5-5',
          const AiUsage(inputTokens: 1000000, outputTokens: 100000),
        )
        ..record(
          AiProviderKind.claude,
          'claude-opus-5-5',
          const AiUsage(inputTokens: 500000, outputTokens: 0),
        )
        ..record(
          AiProviderKind.custom,
          'llama3.2',
          const AiUsage(inputTokens: 300, outputTokens: 40),
        );
      final spend = ledger.spend(prices);
      expect(spend.calls, 3);
      expect(spend.unpricedCalls, 1);
      expect(spend.cost, closeTo(1.5 * 4 + 0.1 * 20, 1e-9));
      expect(
        spend.usage,
        const AiUsage(inputTokens: 1500300, outputTokens: 100040),
      );
      final opus = spend.entries.firstWhere(
        (e) => e.model == 'claude-opus-5-5',
      );
      expect(opus.calls, 2);
      expect(opus.provider, AiProviderKind.claude);

      // Next month starts at nothing; last month is still there.
      now = DateTime(2026, 12, 1);
      expect(ledger.spend(prices).calls, 0);
      expect(ledger.spend(prices, at: DateTime(2026, 11)).calls, 3);
    });

    test('old months are dropped', () {
      ledger.record(AiProviderKind.claude, 'm', const AiUsage(inputTokens: 1));
      now = DateTime(2027, 12, 2);
      ledger.record(AiProviderKind.claude, 'm', const AiUsage(inputTokens: 1));
      expect(store.values.keys.where((k) => k.startsWith('ai.usage.')), [
        'ai.usage.2027-12',
      ]);
    });

    test('the monthly limit blocks calls once reached', () {
      expect(ledger.monthlyCap, isNull);
      ledger.checkCap(prices); // no limit
      ledger.monthlyCap = 1;
      ledger.record(
        AiProviderKind.claude,
        'claude-opus-5-5',
        const AiUsage(inputTokens: 100000, outputTokens: 10000), // $0.60
      );
      expect(ledger.capReached(prices), isFalse);
      ledger.checkCap(prices);
      ledger.record(
        AiProviderKind.claude,
        'claude-opus-5-5',
        const AiUsage(inputTokens: 100000, outputTokens: 10000), // $1.20
      );
      expect(ledger.capReached(prices), isTrue);
      expect(
        () => ledger.checkCap(prices),
        throwsA(
          isA<AiException>()
              .having((e) => e.problem, 'problem', AiProblem.capReached)
              .having((e) => e.message, 'message', contains(r'$1.00')),
        ),
      );
      // A new month, a new budget.
      now = DateTime(2026, 12, 1);
      ledger.checkCap(prices);
      ledger.monthlyCap = null;
      expect(store.values.containsKey('ai.cap'), isFalse);
    });

    test('calls to models without a price do not count to the limit', () {
      ledger.monthlyCap = 0.01;
      ledger.record(
        AiProviderKind.custom,
        'local',
        const AiUsage(inputTokens: 9000000, outputTokens: 9000000),
      );
      expect(ledger.capReached(prices), isFalse);
    });
  });

  group('features', () {
    test('every feature is off until turned on', () {
      final features = AiFeatures(MemoryAiStore());
      for (final f in AiFeatures.all) {
        expect(features.isOn(f.id), isFalse, reason: f.id);
      }
      features.setOn('summaries', true);
      expect(features.isOn('summaries'), isTrue);
      features.setOn('summaries', false);
      expect(features.isOn('summaries'), isFalse);
      expect(AiFeatures.byId('summaries'), AiFeatures.summaries);
      final ids = AiFeatures.all.map((f) => f.id);
      expect(ids.toSet(), hasLength(ids.length));
    });

    test("a feature's own model, else the default", () {
      final features = AiFeatures(MemoryAiStore());
      expect(features.choiceFor('summaries'), isNull);
      features.defaultChoice = const AiChoice(
        AiProviderKind.claude,
        'claude-opus-5-5',
      );
      expect(
        features.choiceFor('summaries'),
        const AiChoice(AiProviderKind.claude, 'claude-opus-5-5'),
      );
      features.setOwnChoice(
        'summaries',
        const AiChoice(AiProviderKind.claude, 'claude-haiku-5-5'),
      );
      expect(features.choiceFor('summaries')!.model, 'claude-haiku-5-5');
      features.setOwnChoice('summaries', null);
      expect(features.choiceFor('summaries')!.model, 'claude-opus-5-5');
    });

    test('confirmed once per feature and recipient', () {
      final features = AiFeatures(MemoryAiStore());
      expect(
        features.confirmed('summaries', AiProviderKind.custom, 'a.lan'),
        isFalse,
      );
      features.confirm('summaries', AiProviderKind.custom, 'a.lan');
      expect(
        features.confirmed('summaries', AiProviderKind.custom, 'a.lan'),
        isTrue,
      );
      // Another address must be agreed to again.
      expect(
        features.confirmed('summaries', AiProviderKind.custom, 'b.lan'),
        isFalse,
      );
      features.forgetConfirmations(AiProviderKind.custom);
      expect(
        features.confirmed('summaries', AiProviderKind.custom, 'a.lan'),
        isFalse,
      );
    });
  });

  test('providers set up, and a custom endpoint address', () {
    final providers = AiProviderSettings(MemoryAiStore());
    expect(providers.configured, isEmpty);
    providers
      ..add(
        AiProviderKind.custom,
        baseUrl: Uri.parse('http://localhost:11434/v1'),
      )
      ..add(AiProviderKind.claude);
    expect(providers.configured, [
      AiProviderKind.claude,
      AiProviderKind.custom,
    ]);
    expect(
      providers.baseUrl(AiProviderKind.custom).toString(),
      'http://localhost:11434/v1',
    );
    expect(
      providers.baseUrl(AiProviderKind.claude).toString(),
      'https://api.anthropic.com',
    );
    providers.remove(AiProviderKind.claude);
    expect(providers.configured, [AiProviderKind.custom]);
  });

  test(
    'the fake provider records requests and answers from a script',
    () async {
      final fake = FakeAiProvider(
        replies: [
          const FakeAiReply('Hello there', chunks: ['Hello', ' there']),
          const FakeAiReply.error(
            AiException(AiProblem.rateLimited, 'slow down'),
          ),
        ],
      );
      const request = AiRequest(model: 'fake-large', messages: []);
      final events = await fake.stream(request).toList();
      expect(events.whereType<AiTextDelta>().map((e) => e.text), [
        'Hello',
        ' there',
      ]);
      expect((events.last as AiCompleted).response.text, 'Hello there');
      await expectLater(fake.complete(request), throwsA(isA<AiException>()));
      expect((await fake.complete(request)).text, 'A fake answer.');
      expect(fake.requests, hasLength(3));
      expect(fake.cancelled, 0);
    },
  );

  test('a new Claude key starts with the default model, which has a price', () {
    expect(AiProviderKind.claude.defaultModel, 'claude-opus-5-5');
    expect(
      AiPriceTable(MemoryAiStore())
          .price(AiProviderKind.claude, AiProviderKind.claude.defaultModel!),
      const AiPrice(4, 20),
    );
    // Others start with the first model their list names.
    for (final kind in [
      AiProviderKind.openai,
      AiProviderKind.llama,
      AiProviderKind.custom,
    ]) {
      expect(kind.defaultModel, isNull, reason: kind.id);
    }
  });
}
