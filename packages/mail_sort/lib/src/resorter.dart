// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import 'ai_sorting.dart';
import 'classification.dart';
import 'header_rule_classifier.dart';
import 'learned_classifier.dart';
import 'list_id.dart';
import 'verification_codes.dart';

/// Re-sorts stored mail from its stored headers when the rules change
/// (and once after upgrading from a version without sorting). Nothing is
/// downloaded. A message the optional AI sorter placed keeps its place
/// while the rules stay unsure about it ([AiSortLog]).
final class Resorter {
  /// By default the same sorting as sync: the header rules plus what each
  /// sender's other mail shows.
  Resorter(this._store, {MessageClassifier? classifier, this.batchSize = 500})
    : classifier =
          classifier ??
          LearnedClassifier(
            const HeaderRuleClassifier(),
            StoreSenderHistory(_store),
          );

  static const versionKey = 'sorting.rulesVersion';

  final MailStore _store;
  final MessageClassifier classifier;

  /// Messages per transaction. Between batches other work (and the UI)
  /// gets a turn.
  final int batchSize;

  /// Whether stored categories were computed with other rules.
  bool get isNeeded =>
      _store.settings.read(versionKey) != '${classifier.version}';

  /// Re-sorts everything if [isNeeded]. Returns how many messages were
  /// looked at.
  Future<int> resortIfNeeded() async => isNeeded ? resortAll() : 0;

  /// Re-sorts every stored message. Safe to interrupt: the version is
  /// recorded only at the end, so an interrupted run starts again.
  ///
  /// Waits [pause] between batches (so the UI keeps drawing), and ends
  /// early, without recording the version, once [stopped] says so (the
  /// app is closing).
  Future<int> resortAll({
    Duration pause = Duration.zero,
    bool Function()? stopped,
  }) async {
    var afterId = 0;
    var count = 0;
    final ai = AiSortLog(_store).applied();
    while (true) {
      if (stopped?.call() ?? false) return count;
      // Reading and writing in one transaction keeps each batch atomic.
      final last = _store.transaction(() {
        final batch = _store.messages.sortable(
          afterId: afterId,
          limit: batchSize,
        );
        if (batch.isEmpty) return null;
        _store.messages.updateCategories([
          for (final message in batch) decide(message, ai: ai),
        ]);
        count += batch.length;
        return batch.last.id;
      });
      if (last == null) break;
      afterId = last;
      await Future<void>.delayed(pause);
    }
    _store.settings.write(versionKey, '${classifier.version}');
    return count;
  }

  /// The decision for one stored message: the rules', or, while they
  /// are unsure, the AI sorter's in [ai] (by message id).
  CategoryDecision decide(
    SortableMessage message, {
    Map<int, AiSortEntry> ai = const {},
  }) {
    var decision = classifier.classify(
      ClassificationInput(
        from: message.from,
        headers: message.headers,
        mailboxUse: message.mailboxUse,
        subject: message.subject,
        snippet: message.snippet,
      ),
    );
    if (decision.unsure) {
      if (ai[message.id] case AiSortEntry(:final category?, :final outcome)) {
        decision = Classification(
          category,
          outcome == AiSortOutcome.corrected
              ? SortingReason.userChoice
              : SortingReason.ai,
        );
      }
    }
    return CategoryDecision(
      messageId: message.id,
      category: decision.category,
      source: decision.source,
      listId: ListId.fromHeaders(message.headers),
      code: decision.category == MessageCategory.codes
          ? VerificationCodes.inMessage(message.subject, message.snippet)
          : null,
    );
  }
}
