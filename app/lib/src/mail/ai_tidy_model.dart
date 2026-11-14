// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_ai/mail_ai.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../services/ai_assistant.dart';
import 'ai_tidy.dart';
import 'mail_controller.dart';
import 'mail_location.dart';

/// "Ask AI to tidy": which emails a request is about, asking the model
/// (through the feature's provider, within the monthly limit), and doing
/// the changes the user ticked as one batch with one Undo.
final class AiTidy {
  AiTidy(this.controller, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final MailController controller;
  final DateTime Function() _clock;

  static String get featureId => AiFeatures.actions.id;

  MailStore get _store => controller.services.store;

  /// Whether the list at [location] can be tidied (not the Outbox or
  /// "Waiting for a reply", whose rows aren't ordinary mail).
  static bool worksIn(MailLocation location) => switch (location) {
    OutboxLocation() || FollowUpsLocation() => false,
    _ => true,
  };

  /// The selected emails, or else (up to [TidyCandidates.cap], newest
  /// first) the list the user is in.
  TidyCandidates candidates() {
    final selected = controller.selection.value;
    if (selected.isNotEmpty) {
      return TidyCandidates([
        for (final id in selected) ?_store.messages.byId(id),
      ]);
    }
    const limit = TidyCandidates.cap + 1;
    List<int>? accounts(int? id) => id == null ? null : [id];
    final location = controller.location.value;
    final messages = switch (location) {
      InboxLocation(:final accountId) => [
        for (final m in _store.messages.list(
          MessageQuery.inbox(accountIds: accounts(accountId), limit: limit),
        ))
          // Snoozed mail isn't in the inbox until it comes back.
          if (m.section != SmartSection.snoozed) m,
      ],
      SectionLocation(:final section, :final accountId) => _store.messages.list(
        MessageQuery.smart(
          section,
          accountIds: accounts(accountId),
          limit: limit,
        ),
      ),
      FolderLocation(:final mailboxId) => _store.messages.list(
        MessageQuery(mailboxIds: [mailboxId], limit: limit),
      ),
      PinsLocation() => _store.messages.list(
        MessageQuery(flaggedOnly: true, limit: limit),
      ),
      SearchLocation() || SnoozedLocation() => controller.list.messages,
      OutboxLocation() || FollowUpsLocation() => const <StoredMessage>[],
    };
    return TidyCandidates(messages);
  }

  TidyPlanner planner() => TidyPlanner(
    _store,
    now: _clock(),
    canSnooze: controller.canSnooze,
    snoozedUntil: (m) =>
        m.messageId == null ? null : _store.snoozes.find(m.messageId!)?.until,
  );

  /// Asks [provider] what to do about [candidates] for the user's
  /// [words], and checks the answer. A request just like an earlier one
  /// (same words, same emails as they are now, same folders, within
  /// [cacheFor]) is answered from that earlier answer, checked again,
  /// without a new call. Throws [AiException].
  Future<TidyPlan> suggest(
    AiFeatureProvider provider,
    String words,
    TidyCandidates candidates, {
    AiCancel? cancel,
  }) async {
    final planner = this.planner();
    final key = _cacheKey(provider, words, candidates, planner);
    final cache = _caches[controller.services.ai] ??= _TidyCache();
    if (cache.get(key, _clock()) case final json?) {
      return planner.check(json, candidates);
    }
    final request = planner.request(
      model: provider.model,
      words: words,
      candidates: candidates,
    );
    final response = await provider.complete(request, cancel: cancel);
    if (response.stopReason == AiStopReason.refusal) {
      throw const AiException(AiProblem.refused, 'declined');
    }
    final json = TidyPlanner.answerJson(response);
    if (json == null) {
      throw const AiException(AiProblem.badResponse, 'not a plan');
    }
    cache.put(key, json, _clock());
    return planner.check(json, candidates);
  }

  /// Answers kept per assistant (so per app), in memory only.
  static final _caches = Expando<_TidyCache>('tidy answers');

  /// How long an answer is reused for the same request.
  static const cacheFor = Duration(minutes: 15);

  static String _cacheKey(
    AiFeatureProvider provider,
    String words,
    TidyCandidates candidates,
    TidyPlanner planner,
  ) => jsonEncode([
    provider.kind.id,
    provider.recipient,
    provider.model,
    words.trim().toLowerCase(),
    planner.folderNames(candidates),
    [
      for (final m in candidates.messages)
        [m.id, m.mailboxId, m.flags.bits, m.section.index],
    ],
  ]);

  // ---------------------------------------------------------------- doing

  /// Does [steps] (with the messages the user left ticked) through the
  /// app's own actions, as one batch: read and pin changes first, then
  /// snoozes, then moves. Says what was done, with one Undo for all of
  /// it. Each email is read again first, so a change made meanwhile isn't
  /// undone by mistake.
  void run(List<TidyStep> steps) {
    final services = controller.services;
    final actions = services.actions;
    final planner = this.planner();
    StoredMessage? fresh(StoredMessage m) => _store.messages.byId(m.id);
    final flagged = <FlagReceipt>[];
    final removed = <RemovalReceipt>[];
    final snoozedBefore = <String, Snooze?>{};
    final done = <String>[];
    final leaving = <int>{};

    // Read and pinned.
    for (final step in steps) {
      final messages = [for (final m in step.messages) ?fresh(m)];
      if (messages.isEmpty) continue;
      final receipt = switch (step.kind) {
        TidyKind.markRead => actions.markRead(messages),
        TidyKind.markUnread => actions.markRead(messages, read: false),
        TidyKind.pin => actions.markFlagged(messages),
        TidyKind.unpin => actions.markFlagged(messages, flagged: false),
        _ => null,
      };
      if (receipt == null) continue;
      flagged.add(receipt);
      if (receipt.changed.isNotEmpty) {
        done.add(describeDone(step.kind, receipt.changed.length));
      }
    }

    // Snoozed: only on this device and in synced settings, like the
    // Snooze button.
    for (final step in steps.where((s) => s.kind == TidyKind.snooze)) {
      final messages = [
        for (final m in step.messages)
          if (fresh(m) case final f? when controller.canSnooze(f)) f,
      ];
      if (messages.isEmpty) continue;
      _store.transaction(() {
        for (final m in messages) {
          final id = m.messageId!;
          snoozedBefore.putIfAbsent(id, () => _store.snoozes.find(id));
          _store.snoozes.snooze(id, step.until!);
        }
      });
      leaving.addAll(messages.map((m) => m.id));
      done.add(describeDone(TidyKind.snooze, messages.length));
    }

    // Archived and moved.
    for (final step in steps) {
      if (step.kind != TidyKind.archive && step.kind != TidyKind.move) {
        continue;
      }
      final byTarget = <int, (StoredMailbox, List<StoredMessage>)>{};
      for (final m in step.messages) {
        final f = fresh(m);
        if (f == null) continue;
        final target = step.kind == TidyKind.archive
            ? MailActions.archiveFolder(_store, f.accountId)
            : planner.folderIn(f.accountId, step.folder!);
        if (target == null || target.id == f.mailboxId) continue;
        byTarget.putIfAbsent(target.id, () => (target, [])).$2.add(f);
      }
      var count = 0;
      for (final (target, group) in byTarget.values) {
        final receipt = actions.move(group, target);
        removed.add(receipt);
        for (final id in receipt.accountIds) {
          services.worker.syncAt(id, receipt.undoUntil);
        }
        leaving.addAll(group.map((m) => m.id));
        count += group.length;
      }
      if (count > 0) {
        done.add(describeDone(step.kind, count, folder: step.folder));
      }
    }

    final flagAccounts = {for (final r in flagged) ...r.accountIds};
    for (final id in flagAccounts) {
      services.worker.requestSync(id);
    }
    controller.clearSelection();
    if (controller.selected case final open? when leaving.contains(open.id)) {
      controller.closeMessage();
    }
    controller.refresh();
    if (done.isEmpty) {
      controller.onNotice?.call('Nothing needed changing.');
      return;
    }
    controller.onNotice?.call(
      _sentence(done),
      undo: () {
        var undone = true;
        for (final r in removed.reversed) {
          if (!actions.undo(r)) undone = false;
        }
        _store.transaction(() {
          for (final MapEntry(key: id, value: before)
              in snoozedBefore.entries) {
            if (before == null) {
              _store.snoozes.cancel(id);
            } else {
              _store.snoozes.snooze(id, before.until);
            }
          }
        });
        for (final r in flagged.reversed) {
          actions.undo(r);
        }
        for (final id in flagAccounts) {
          services.worker.requestSync(id);
        }
        controller.refresh();
        if (!undone) {
          controller.onNotice?.call(
            'Too late to undo the moves: they reached the server.',
          );
        }
      },
    );
  }

  /// "Archived 12", "Moved 3 to Receipts", "Marked 2 as read".
  static String describeDone(TidyKind kind, int n, {String? folder}) =>
      switch (kind) {
        TidyKind.archive => 'Archived $n',
        TidyKind.move => 'Moved $n to ${folder ?? 'a folder'}',
        TidyKind.markRead => 'Marked $n as read',
        TidyKind.markUnread => 'Marked $n as unread',
        TidyKind.pin => 'Pinned $n',
        TidyKind.unpin => 'Unpinned $n',
        TidyKind.snooze => 'Snoozed $n',
      };

  /// "Archived 12, pinned 2 and snoozed 1".
  static String _sentence(List<String> parts) {
    final lower = [
      parts.first,
      for (final p in parts.skip(1)) p[0].toLowerCase() + p.substring(1),
    ];
    if (lower.length == 1) return lower.single;
    return '${lower.sublist(0, lower.length - 1).join(', ')} and '
        '${lower.last}';
  }
}

/// A few recent answers, each for [AiTidy.cacheFor].
final class _TidyCache {
  static const size = 8;
  final _entries = <String, (DateTime, Map<String, Object?>)>{};

  Map<String, Object?>? get(String key, DateTime now) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (now.difference(entry.$1) > AiTidy.cacheFor) {
      _entries.remove(key);
      return null;
    }
    return entry.$2;
  }

  void put(String key, Map<String, Object?> json, DateTime now) {
    _entries.remove(key);
    _entries[key] = (now, json);
    while (_entries.length > size) {
      _entries.remove(_entries.keys.first);
    }
  }
}
