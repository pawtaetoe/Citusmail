// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';

import '../../../core/state/page_model.dart';
import '../../inbox/state/mail_controller.dart';

/// The Clean up page's senders: those listed ([groups], most mail
/// first), those the user keeps ([keptGroups]), and the kept keys.
typedef SenderCleanupData = ({
  List<SenderGroup> groups,
  List<SenderGroup> keptGroups,
  Set<String> kept,
});

/// The Clean up page's data: senders ranked by how much mail they send
/// and how much of it is opened, from the mail on the device, read again
/// as the mail changes. Acting on a sender goes through [MailController],
/// like the list's own actions.
final class SenderCleanupModel extends PageModel<SenderCleanupData> {
  SenderCleanupModel(this.controller, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(reloadOn: controller.counts);

  final MailController controller;
  final DateTime Function() _now;

  MailStore get _store => controller.services.store;

  /// The senders kept (synced between devices, so declared there).
  static const keptSetting = SyncedPreferences.keptSenders;

  /// Senders the user chose to keep, by [SenderGroup.key].
  Set<String> get kept => data?.kept ?? const {};

  /// The kept senders that still send mail.
  List<SenderGroup> get keptGroups => data?.keptGroups ?? const [];

  SenderOrder _order = SenderOrder.mostMail;
  bool _bulkOnly = true;

  SenderOrder get order => _order;
  set order(SenderOrder value) {
    _order = value;
    notifyListeners();
  }

  /// Only newsletters and notifications (else every sender).
  bool get bulkOnly => _bulkOnly;
  set bulkOnly(bool value) {
    _bulkOnly = value;
    notifyListeners();
  }

  /// The senders listed, in [order].
  List<SenderGroup> get shown => SenderCleanup.sort([
    for (final g in data?.groups ?? const <SenderGroup>[])
      if (!_bulkOnly || g.isBulk) g,
  ], _order);

  /// Since when the senders' mail is counted: [SenderCleanup.window]
  /// (3 months) back from now.
  DateTime get since => _now().subtract(SenderCleanup.window);

  @override
  Future<SenderCleanupData> fetch() async {
    final kept = {...keptSetting.read(_store.settings)};
    // The store adds the mail up per sender; grouping senders by company
    // happens off the UI thread.
    final senders = _store.messages.senderStats(since);
    final all = await compute(_group, (
      senders,
      {for (final a in _store.accounts.all()) a.email.toLowerCase()},
      _store.messages.writtenTo(),
    ));
    // Blocked senders' mail already goes to Junk.
    final listed = [
      for (final g in all)
        if (!g.addresses.any((a) => _store.blocks.matching(a) != null)) g,
    ];
    return _split(listed, kept);
  }

  static SenderCleanupData _split(List<SenderGroup> all, Set<String> kept) => (
    groups: [
      for (final g in all)
        if (!kept.contains(g.key)) g,
    ],
    keptGroups: [
      for (final g in all)
        if (kept.contains(g.key)) g,
    ],
    kept: kept,
  );

  /// "Keep": the senders are no longer listed (undo with [unkeep]).
  void keep(Iterable<SenderGroup> groups) =>
      _setKept({...kept, for (final g in groups) g.key});

  void unkeep(Iterable<String> keys) => _setKept({...kept}..removeAll(keys));

  void _setKept(Set<String> keys) {
    keptSetting.write(_store.settings, keys.toList());
    // At once, without waiting for the next read.
    if (data case final d?) {
      change(_split([...d.groups, ...d.keptGroups], keys));
    }
  }

  /// The mail of [groups] in the inboxes (any age), that "Archive all"
  /// moves: not pinned mail.
  List<StoredMessage> inboxMail(Iterable<SenderGroup> groups) {
    final accounts = _store.accounts.all();
    final seen = <MessageId>{};
    return SenderCleanup.actionable([
      for (final g in groups)
        for (final address in g.addresses)
          for (final account in accounts)
            for (final m in _store.messages.inboxFromList(
              account.id,
              fromAddress: address,
              limit: 5000,
            ))
              if (seen.add(m.id)) m,
    ]);
  }

  /// The mail of [groups] that "Delete all" moves to Trash (any age):
  /// what this page counts, in every folder but Sent, Drafts, Trash and
  /// Junk, each message once (the original, not a Gmail copy in All
  /// Mail); not pinned mail.
  List<StoredMessage> allMail(Iterable<SenderGroup> groups) =>
      SenderCleanup.actionable(
        _store.messages.receivedFrom([for (final g in groups) ...g.addresses]),
      );

  /// [mail] (what [inboxMail] or [allMail] gave) with, of it, what came
  /// in the period the page counts ([since]): what Archive and Delete
  /// offer, "only the last 3 months" or all of it.
  static CleanupScope scopeOf(List<StoredMessage> mail, DateTime since) =>
      CleanupScope(mail, [
        for (final m in mail)
          if (!m.receivedAt.isBefore(since)) m,
      ]);

  /// The newest message of [group] (for blocking).
  StoredMessage? newest(SenderGroup group) =>
      _store.messages.byId(group.newestId);

  /// The newest message of [group] with unsubscribe headers.
  StoredMessage? unsubscribeMessage(SenderGroup group) =>
      group.unsubscribeId == null
      ? null
      : _store.messages.byId(group.unsubscribeId!);

  /// When the user unsubscribed from [group], if they did.
  Unsubscription? unsubscribed(SenderGroup group) {
    final m = unsubscribeMessage(group);
    return m == null ? null : controller.unsubscriptionFor(m);
  }
}

/// Top level, for [compute].
List<SenderGroup> _group((List<SenderStats>, Set<String>, Set<String>) input) {
  final (senders, own, writtenTo) = input;
  return SenderCleanup.groupSenders(
    senders,
    domainOf: (domain) => Domains.registrable(domain) ?? domain.toLowerCase(),
    own: own,
    writtenTo: writtenTo,
  );
}

/// The mail a Clean up action can take: [all] of it, any age, and of
/// it the [recent] mail, from the period the cards count.
final class CleanupScope {
  const CleanupScope(this.all, this.recent);

  final List<StoredMessage> all;
  final List<StoredMessage> recent;

  /// How many of [all] are older than the period.
  int get older => all.length - recent.length;

  /// Whether there is a choice to offer: some recent mail, some older.
  bool get hasChoice => recent.isNotEmpty && older > 0;
}
