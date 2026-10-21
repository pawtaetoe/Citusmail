// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import 'classification.dart';
import 'header_rule_classifier.dart';
import 'list_id.dart';

/// Re-sorts stored mail from its stored headers when the rules change
/// (and once after upgrading from a version without sorting). Nothing is
/// downloaded; the user's choices stay on top.
final class Resorter {
  Resorter(
    this._store, {
    this.classifier = const HeaderRuleClassifier(),
    this.batchSize = 500,
  });

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
  Future<int> resortAll() async {
    var afterId = 0;
    var count = 0;
    while (true) {
      // Reading and writing in one transaction keeps each batch atomic.
      final last = _store.transaction(() {
        final batch = _store.messages.sortable(
          afterId: afterId,
          limit: batchSize,
        );
        if (batch.isEmpty) return null;
        _store.messages.updateAutomaticCategories([
          for (final message in batch) decide(message),
        ]);
        count += batch.length;
        return batch.last.id;
      });
      if (last == null) break;
      afterId = last;
      await Future<void>.delayed(Duration.zero);
    }
    _store.settings.write(versionKey, '${classifier.version}');
    return count;
  }

  /// The automatic decision for one stored message.
  AutomaticCategory decide(SortableMessage message) {
    final decision = classifier.classify(
      ClassificationInput(
        from: message.from,
        headers: message.headers,
        mailboxUse: message.mailboxUse,
      ),
    );
    return AutomaticCategory(
      messageId: message.id,
      category: decision.category,
      source: decision.source,
      listId: ListId.fromHeaders(message.headers),
    );
  }
}
