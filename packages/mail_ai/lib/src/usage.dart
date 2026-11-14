// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'ai_errors.dart';
import 'ai_settings.dart';
import 'ai_types.dart';

/// What a model costs, in US dollars per million tokens (providers bill
/// in dollars).
final class AiPrice {
  const AiPrice(this.inputPerMillion, this.outputPerMillion);

  final double inputPerMillion;
  final double outputPerMillion;

  double cost(AiUsage usage) =>
      (usage.inputTokens * inputPerMillion +
          usage.outputTokens * outputPerMillion) /
      1e6;

  @override
  bool operator ==(Object other) =>
      other is AiPrice &&
      other.inputPerMillion == inputPerMillion &&
      other.outputPerMillion == outputPerMillion;

  @override
  int get hashCode => Object.hash(inputPerMillion, outputPerMillion);

  @override
  String toString() => 'AiPrice($inputPerMillion, $outputPerMillion)';
}

/// Prices per provider and model: Anthropic's published prices filled in,
/// the rest unknown until the user enters them (they can change any of
/// them).
final class AiPriceTable {
  AiPriceTable(this._store);

  final AiStore _store;

  static const _key = 'ai.prices';

  /// List prices (input / output per million tokens), as published:
  /// Anthropic's (for Haiku, the price for prompts up to 100,000 tokens;
  /// mail rarely is longer) and Meta's for Muse Spark 1.1. The user can
  /// change any of them.
  static const defaults = <String, AiPrice>{
    'claude/claude-opus-5-5': AiPrice(4, 20),
    'claude/claude-sonnet-5-5': AiPrice(2, 10),
    'claude/claude-haiku-5-5': AiPrice(0.10, 0.50),
    'meta/muse-spark-1.1': AiPrice(1.25, 4.25),
  };

  static String _id(AiProviderKind kind, String model) => '${kind.id}/$model';

  Map<String, Object?> _overrides() {
    try {
      final value = jsonDecode(_store.read(_key) ?? '{}');
      return value is Map<String, Object?> ? value : {};
    } on FormatException {
      return {};
    }
  }

  /// [model]'s price, or null if unknown. A dated model id
  /// (`claude-haiku-5-5-20261101`) has its alias's price.
  AiPrice? price(AiProviderKind kind, String model) {
    final id = _id(kind, model);
    final own = _overrides();
    if (own.containsKey(id)) return _parse(own[id]);
    if (defaults[id] case final known?) return known;
    final alias = defaults.keys
        .where((k) => id.startsWith('$k-'))
        .fold<String?>(
          null,
          (best, k) => best == null || k.length > best.length ? k : best,
        );
    return alias == null ? null : defaults[alias];
  }

  /// Whether the user changed [model]'s price.
  bool isOwn(AiProviderKind kind, String model) =>
      _overrides().containsKey(_id(kind, model));

  /// Sets [model]'s price; null makes it unknown.
  void setPrice(AiProviderKind kind, String model, AiPrice? price) {
    final own = _overrides();
    own[_id(kind, model)] = price == null
        ? null
        : [price.inputPerMillion, price.outputPerMillion];
    _store.write(_key, jsonEncode(own));
  }

  /// Back to the filled-in price (or unknown).
  void reset(AiProviderKind kind, String model) {
    final own = _overrides()..remove(_id(kind, model));
    _store.write(_key, jsonEncode(own));
  }

  static AiPrice? _parse(Object? value) {
    if (value is List && value.length == 2) {
      final [a, b] = value;
      if (a is num && b is num && a >= 0 && b >= 0) {
        return AiPrice(a.toDouble(), b.toDouble());
      }
    }
    return null;
  }
}

/// One model's use in a month.
final class AiUsageEntry {
  const AiUsageEntry({
    required this.provider,
    required this.model,
    required this.usage,
    required this.calls,
  });

  final AiProviderKind provider;
  final String model;
  final AiUsage usage;
  final int calls;
}

/// A month's use, added up.
final class AiSpend {
  const AiSpend({
    required this.entries,
    required this.cost,
    required this.unpricedCalls,
  });

  final List<AiUsageEntry> entries;

  /// In US dollars, for the models with a price.
  final double cost;

  /// Calls to models without a known price (not in [cost]).
  final int unpricedCalls;

  int get calls => entries.fold(0, (n, e) => n + e.calls);

  AiUsage get usage => entries.fold(AiUsage.zero, (u, e) => u + e.usage);
}

/// Tokens used per provider and model, per month, on this device; and
/// the user's monthly spending limit, which stops further calls once
/// reached.
final class AiUsageLedger {
  AiUsageLedger(this._store, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AiStore _store;
  final DateTime Function() _now;

  static const _capKey = 'ai.cap';
  static String _monthKey(DateTime at) =>
      'ai.usage.${at.year}-${at.month.toString().padLeft(2, '0')}';

  /// How long a month's numbers are kept.
  static const keepMonths = 13;

  Map<String, Object?> _month(DateTime at) {
    try {
      final value = jsonDecode(_store.read(_monthKey(at)) ?? '{}');
      return value is Map<String, Object?> ? value : {};
    } on FormatException {
      return {};
    }
  }

  /// Adds one call's [usage].
  void record(AiProviderKind provider, String model, AiUsage usage) {
    final now = _now();
    final month = _month(now);
    final id = '${provider.id}/$model';
    final old = month[id];
    int get(String name) =>
        old is Map<String, Object?> && old[name] is int ? old[name]! as int : 0;
    month[id] = {
      'in': get('in') + usage.inputTokens,
      'out': get('out') + usage.outputTokens,
      'calls': get('calls') + 1,
    };
    _store.write(_monthKey(now), jsonEncode(month));
    // The month a year ago goes.
    _store.delete(_monthKey(DateTime(now.year, now.month - keepMonths)));
  }

  /// The use in the month of [at] (this month by default), priced with
  /// [prices].
  AiSpend spend(AiPriceTable prices, {DateTime? at}) {
    final entries = <AiUsageEntry>[];
    var cost = 0.0;
    var unpriced = 0;
    for (final MapEntry(:key, :value) in _month(at ?? _now()).entries) {
      final slash = key.indexOf('/');
      final provider = AiProviderKind.byId(
        slash < 0 ? null : key.substring(0, slash),
      );
      if (provider == null || value is! Map<String, Object?>) continue;
      int get(String name) => value[name] is int ? value[name]! as int : 0;
      final entry = AiUsageEntry(
        provider: provider,
        model: key.substring(slash + 1),
        usage: AiUsage(inputTokens: get('in'), outputTokens: get('out')),
        calls: get('calls'),
      );
      entries.add(entry);
      if (prices.price(provider, entry.model) case final price?) {
        cost += price.cost(entry.usage);
      } else {
        unpriced += entry.calls;
      }
    }
    return AiSpend(entries: entries, cost: cost, unpricedCalls: unpriced);
  }

  /// The most to spend in a month, in US dollars (null: no limit).
  double? get monthlyCap => double.tryParse(_store.read(_capKey) ?? '');
  set monthlyCap(double? dollars) => dollars == null || dollars < 0
      ? _store.delete(_capKey)
      : _store.write(_capKey, dollars.toString());

  /// Whether this month's spending reached [monthlyCap].
  bool capReached(AiPriceTable prices) {
    final cap = monthlyCap;
    return cap != null && spend(prices).cost >= cap;
  }

  /// Throws [AiException] with [AiProblem.capReached] when this month's
  /// limit is reached; call before every request.
  void checkCap(AiPriceTable prices) {
    final cap = monthlyCap;
    if (cap == null || !capReached(prices)) return;
    throw AiException(
      AiProblem.capReached,
      'This month\'s AI limit of \$${cap.toStringAsFixed(2)} is reached, so '
      'nothing more is sent until next month. You can raise the limit in '
      'Settings, AI assistant.',
    );
  }
}
