// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_store/mail_store.dart';

import 'classification.dart';
import 'header_rule_classifier.dart';
import 'learned_classifier.dart';

// The optional AI assistant as a backup sorter (with the user's own key,
// off by default): the parts that need no AI. Which new mail the rules
// are unsure about ([AiSortCandidates]), what a valid answer is
// ([AiSortAnswer]), and what was asked and decided ([AiSortLog]), so no
// message is asked about twice and a later re-sort keeps the decision.
//
// The rules stay first: only mail they have no signal for
// ([Classification.unsure]) is ever offered, and a decision applies only
// while the rules stay unsure.

/// The assistant's answer about one message, checked: a category the app
/// has, a short reason, and whether it is a sign-in or verification code
/// email. Anything else in an answer makes it invalid, so whatever an
/// email asks the model to do, the most it can change is which section
/// that one message is in.
final class AiSortAnswer {
  const AiSortAnswer({
    required this.category,
    required this.reason,
    required this.isVerification,
  });

  /// The category the model named.
  final MessageCategory category;

  /// Why, in one line (model output: shown as plain text only).
  final String reason;

  /// Whether the model says it is a sign-in or verification code email.
  final bool isVerification;

  /// Where the message goes: Codes for verification mail (so the code is
  /// read from it), else [category].
  MessageCategory get decided =>
      isVerification ? MessageCategory.codes : category;

  /// The names the model may answer with.
  static const categoryNames = {
    'general': MessageCategory.general,
    'newsletters': MessageCategory.newsletters,
    'notifications': MessageCategory.notifications,
    'codes': MessageCategory.codes,
  };

  /// The longest reason kept.
  static const maxReason = 160;

  /// The structured output asked for (JSON Schema).
  static const Map<String, Object?> schema = {
    'type': 'object',
    'additionalProperties': false,
    'required': ['category', 'reason', 'isVerification'],
    'properties': {
      'category': {
        'type': 'string',
        'enum': ['general', 'newsletters', 'notifications', 'codes'],
        'description':
            'general: personal or one-off mail that needs a person; '
            'newsletters: marketing, newsletters, digests; '
            'notifications: automatic messages from services (receipts, '
            'alerts, statements, shipping); codes: sign-in codes, '
            'verification and password reset mail.',
      },
      'reason': {
        'type': 'string',
        'description': 'One short sentence, under 15 words.',
      },
      'isVerification': {
        'type': 'boolean',
        'description':
            'Whether this email gives a sign-in code, a verification code '
            'or link, or a password reset.',
      },
    },
  };

  /// The answer in [json], or null unless it is exactly the shape of
  /// [schema]: one of [categoryNames], a non-empty reason, a boolean, and
  /// nothing else.
  static AiSortAnswer? parse(Map<String, Object?>? json) {
    if (json == null || json.length != 3) return null;
    final category = categoryNames[json['category']];
    final reason = json['reason'];
    final verification = json['isVerification'];
    if (category == null || reason is! String || verification is! bool) {
      return null;
    }
    final line = cleanReason(reason);
    if (line.isEmpty) return null;
    return AiSortAnswer(
      category: category,
      reason: line,
      isVerification: verification,
    );
  }

  /// [text] on one line, without control or invisible characters, at
  /// most [maxReason] characters.
  static String cleanReason(String text) {
    final line = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(_hidden, '')
        .trim();
    return line.length <= maxReason
        ? line
        : '${line.substring(0, maxReason - 1).trimRight()}…';
  }

  /// Control characters and invisible formatting (zero-width,
  /// bidirectional controls, soft hyphen...).
  static final _hidden = RegExp(r'[\p{Cc}\p{Cf}]', unicode: true);
}

/// What came of asking about one message.
enum AiSortOutcome {
  /// The message was moved to the answer's category.
  applied,

  /// The answer was General, or the message had moved meanwhile: nothing
  /// changed.
  kept,

  /// The answer was not valid, or the provider declined: ignored.
  ignored,

  /// The user put it back ("Not right?"): the rules decide again, and it
  /// is never asked about again.
  undone,
}

/// One message asked about. Kept so it is never asked again, so a
/// re-sort keeps the decision, and so a later stage could learn rules
/// from the decisions (sender, list and category; no text of the mail).
final class AiSortEntry {
  const AiSortEntry({
    required this.messageId,
    required this.outcome,
    required this.at,
    this.category,
    this.reason,
    this.verification = false,
    this.by,
    this.sender,
    this.listId,
  });

  /// The stored message's id.
  final int messageId;
  final AiSortOutcome outcome;
  final DateTime at;

  /// What the answer decided ([AiSortAnswer.decided]), when it was valid.
  final MessageCategory? category;

  /// The answer's reason, when it was valid.
  final String? reason;
  final bool verification;

  /// Who answered ("Anthropic", or a custom endpoint's host).
  final String? by;

  /// The sender's address (lower case) and the mailing list, for learning
  /// later.
  final String? sender;
  final String? listId;

  AiSortEntry withOutcome(AiSortOutcome outcome) => AiSortEntry(
    messageId: messageId,
    outcome: outcome,
    at: at,
    category: category,
    reason: reason,
    verification: verification,
    by: by,
    sender: sender,
    listId: listId,
  );

  Map<String, Object?> toJson() => {
    'id': messageId,
    'outcome': outcome.name,
    'at': at.toUtc().millisecondsSinceEpoch,
    if (category != null) 'category': category!.name,
    'reason': ?reason,
    if (verification) 'verification': true,
    'by': ?by,
    'sender': ?sender,
    'list': ?listId,
  };

  static AiSortEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final at = json['at'];
    final outcome = AiSortOutcome.values
        .where((o) => o.name == json['outcome'])
        .firstOrNull;
    if (id is! int || at is! int || outcome == null) return null;
    String? text(String key) =>
        json[key] is String ? json[key]! as String : null;
    return AiSortEntry(
      messageId: id,
      outcome: outcome,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      category: MessageCategory.values
          .where((c) => c.name == json['category'])
          .firstOrNull,
      reason: text('reason'),
      verification: json['verification'] == true,
      by: text('by'),
      sender: text('sender'),
      listId: text('list'),
    );
  }
}

/// The messages the AI sorter asked about, in the settings store (on the
/// device, encrypted, never synced), newest last, at most [keep].
final class AiSortLog {
  AiSortLog(this._store);

  final MailStore _store;

  static const key = 'ai.sorting.log';

  /// Entries kept at most; the oldest go first (their mail is long past
  /// the age the sorter looks at).
  static const keep = 500;

  List<AiSortEntry> get entries {
    final raw = _store.settings.read(key);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List<Object?>) return const [];
      return [for (final item in list) ?AiSortEntry.fromJson(item)];
    } on FormatException {
      return const [];
    }
  }

  void _write(List<AiSortEntry> entries) {
    final kept = entries.length > keep
        ? entries.sublist(entries.length - keep)
        : entries;
    _store.settings.write(key, jsonEncode([for (final e in kept) e.toJson()]));
  }

  /// The messages asked about (whatever came of it).
  Set<int> get asked => {for (final e in entries) e.messageId};

  AiSortEntry? forMessage(int messageId) =>
      entries.where((e) => e.messageId == messageId).lastOrNull;

  /// Records [entry], in place of an earlier one for the same message.
  void add(AiSortEntry entry) => _write([
    for (final e in entries)
      if (e.messageId != entry.messageId) e,
    entry,
  ]);

  /// The decisions in force, by message id.
  Map<int, AiSortEntry> applied() => {
    for (final e in entries)
      if (e.outcome == AiSortOutcome.applied && e.category != null)
        e.messageId: e,
  };

  /// The user put [messageId] back: its decision no longer applies.
  void undo(int messageId) {
    final entry = forMessage(messageId);
    if (entry == null) return;
    add(entry.withOutcome(AiSortOutcome.undone));
  }

  /// Forgets everything (the feature's "forget" and tests).
  void clear() => _store.settings.delete(key);
}

/// New inbox mail the rules are unsure about, which the AI sorter may
/// ask about: in the General section of an inbox (so not Pinned, Codes,
/// the Screener, Important: mail from people the user writes to or
/// replies to their mail, nor anything a rule, a block or the user's
/// folder rules already placed), received within [maxAge], with no
/// signal for the rules ([Classification.unsure]), and not asked about
/// before. Newest first.
abstract final class AiSortCandidates {
  /// Mail older than this is left alone: the sorter is for new mail.
  static const maxAge = Duration(days: 1);

  /// Messages looked at per search, at most.
  static const maxLooked = 500;

  static List<StoredMessage> find(
    MailStore store, {
    required DateTime now,
    required int limit,
    MessageClassifier? classifier,
    Duration maxAge = maxAge,
  }) {
    if (limit <= 0) return const [];
    final rules =
        classifier ??
        LearnedClassifier(
          const HeaderRuleClassifier(),
          StoreSenderHistory(store),
        );
    final asked = AiSortLog(store).asked;
    final since = now.subtract(maxAge);
    final found = <StoredMessage>[];
    var query = const MessageQuery.smart(SmartSection.general, limit: 50);
    var looked = 0;
    while (found.length < limit && looked < maxLooked) {
      final page = store.messages.list(query);
      if (page.isEmpty) break;
      for (final m in page) {
        looked++;
        if (found.length >= limit) break;
        if (m.receivedAt.isBefore(since) || asked.contains(m.id)) continue;
        if (m.category != MessageCategory.general) continue;
        final decision = rules.classify(
          ClassificationInput(
            from: m.from,
            headers: store.messages.headers(m.id),
            subject: m.subject,
            snippet: m.snippet,
          ),
        );
        if (decision.unsure) found.add(m);
      }
      // Lists are newest first (by when listed): past the age, done.
      if (page.length < query.limit || page.last.listedAt.isBefore(since)) {
        break;
      }
      query = query.after(page.last);
    }
    return found;
  }
}
