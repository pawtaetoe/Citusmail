// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'classification.dart';

/// What the learned sorting may know about a sender: their other stored
/// mail, and whether the user writes to them. All on the device.
abstract interface class SenderHistory {
  /// Up to [limit] of the sender's stored messages, newest first.
  List<ClassificationInput> recentFrom(String address, {int limit});

  /// Whether the user has written to [address].
  bool isCorrespondent(String address);
}

/// [SenderHistory] from the encrypted store.
final class StoreSenderHistory implements SenderHistory {
  const StoreSenderHistory(this._store);

  final MailStore _store;

  @override
  List<ClassificationInput> recentFrom(String address, {int limit = 50}) => [
    for (final m in _store.messages.sortableFrom(address, limit: limit))
      ClassificationInput(
        from: m.from,
        headers: m.headers,
        mailboxUse: m.mailboxUse,
        subject: m.subject,
        snippet: m.snippet,
      ),
  ];

  @override
  bool isCorrespondent(String address) => _store.messages.hasWrittenTo(address);
}

/// Sorting that learns from each sender's own mail, on the device: when
/// the header rules find no signal in a message, the sender's other
/// stored mail is sorted by the same rules, and if they clearly agree
/// ([minEvidence] messages with a signal, and at least [agreement] of all
/// the sender's mail), this message follows them.
///
/// So a shop's receipt without list headers lands with the shop's other
/// mail instead of in General, while one-off and personal mail stays in
/// General. Never for people the user writes to. Nothing leaves the
/// device, and the decision is explained ([SortingReason.sameSender]).
final class LearnedClassifier implements MessageClassifier {
  LearnedClassifier(
    this.rules,
    this.history, {
    this.minEvidence = 3,
    this.agreement = 0.9,
    this.sample = 50,
    this.cacheFor = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final MessageClassifier rules;
  final SenderHistory history;
  final int minEvidence;
  final double agreement;

  /// How many of the sender's newest messages are looked at.
  final int sample;

  /// Senders are looked up again after this (new mail changes the
  /// picture); at most [_maxCached] are kept.
  final Duration cacheFor;
  final DateTime Function() _now;

  static const _maxCached = 1000;
  final _cache = <String, (DateTime, MessageCategory?)>{};

  /// Changes with the rules, and with how learning works (re-sorts stored
  /// mail once).
  @override
  int get version => rules.version * 100 + 1;

  @override
  Classification classify(ClassificationInput input) {
    final decision = rules.classify(input);
    if (decision.reason != SortingReason.noSignal) return decision;
    final use = input.mailboxUse;
    if (use == SpecialUse.sent || use == SpecialUse.drafts) return decision;
    final address = input.from?.address.toLowerCase();
    if (address == null) return decision;
    final learned = _learned(address);
    return learned == null
        ? decision
        : Classification(learned, SortingReason.sameSender);
  }

  MessageCategory? _learned(String address) {
    final now = _now();
    final cached = _cache[address];
    if (cached != null && now.difference(cached.$1) < cacheFor) {
      return cached.$2;
    }
    final result = _decide(address);
    if (_cache.length >= _maxCached) _cache.clear();
    _cache[address] = (now, result);
    return result;
  }

  MessageCategory? _decide(String address) {
    final mail = history.recentFrom(address, limit: sample);
    if (mail.length < minEvidence) return null;
    final counts = <MessageCategory, int>{};
    for (final input in mail) {
      final category = rules.classify(input).category;
      counts[category] = (counts[category] ?? 0) + 1;
    }
    for (final MapEntry(key: category, value: count) in counts.entries) {
      // Codes are known from each message itself, never from the sender:
      // a bank's statements are not codes.
      if (category == MessageCategory.general ||
          category == MessageCategory.codes) {
        continue;
      }
      if (count >= minEvidence && count / mail.length >= agreement) {
        // Checked last: one query, only when it would matter.
        return history.isCorrespondent(address) ? null : category;
      }
    }
    return null;
  }
}
