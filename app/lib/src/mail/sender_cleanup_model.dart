// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';

import 'mail_controller.dart';

/// The Clean up page's data: senders ranked by how much mail they send
/// and how much of it is opened, from the mail on the device. Acting on a
/// sender goes through [MailController], like the list's own actions.
final class SenderCleanupModel extends ChangeNotifier {
  SenderCleanupModel(this.controller, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    controller.counts.addListener(_mailChanged);
  }

  final MailController controller;
  final DateTime Function() _now;

  MailStore get _store => controller.services.store;

  static const _keptKey = 'cleanup.kept';

  bool loading = true;

  /// Every sender found, most mail first, without the kept ones.
  List<SenderGroup> _groups = const [];

  /// Senders the user chose to keep, by [SenderGroup.key].
  Set<String> kept = const {};

  /// The kept senders that still send mail.
  List<SenderGroup> keptGroups = const [];

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
    for (final g in _groups)
      if (!_bulkOnly || g.isBulk) g,
  ], _order);

  bool _disposed = false;
  bool _loadAgain = false;
  Future<void>? _loading;

  /// Reads the mail again (once at a time; a request while reading reads
  /// once more after).
  Future<void> load() {
    if (_loading != null) {
      _loadAgain = true;
      return _loading!;
    }
    return _loading = _load().whenComplete(() {
      _loading = null;
      if (_loadAgain && !_disposed) {
        _loadAgain = false;
        unawaited(load());
      }
    });
  }

  Future<void> _load() async {
    kept = {
      ...?_store.settings.read(_keptKey)?.split(',').where((s) => s.isNotEmpty),
    };
    // The store adds the mail up per sender; grouping senders by company
    // happens off the UI thread.
    final senders = _store.messages.senderStats(
      _now().subtract(SenderCleanup.window),
    );
    final all = await compute(_group, (
      senders,
      {for (final a in _store.accounts.all()) a.email.toLowerCase()},
      _store.messages.writtenTo(),
    ));
    if (_disposed) return;
    // Blocked senders' mail already goes to Junk.
    final listed = [
      for (final g in all)
        if (!g.addresses.any((a) => _store.blocks.matching(a) != null)) g,
    ];
    _groups = [
      for (final g in listed)
        if (!kept.contains(g.key)) g,
    ];
    keptGroups = [
      for (final g in listed)
        if (kept.contains(g.key)) g,
    ];
    loading = false;
    notifyListeners();
  }

  void _mailChanged() {
    if (!loading) unawaited(load());
  }

  /// "Keep": the senders are no longer listed (undo with [unkeep]).
  void keep(Iterable<SenderGroup> groups) =>
      _setKept({...kept, for (final g in groups) g.key});

  void unkeep(Iterable<String> keys) => _setKept({...kept}..removeAll(keys));

  void _setKept(Set<String> keys) {
    _store.settings.write(_keptKey, keys.join(','));
    kept = keys;
    // At once, without waiting for the next read.
    final all = [..._groups, ...keptGroups];
    _groups = [
      for (final g in all)
        if (!keys.contains(g.key)) g,
    ];
    keptGroups = [
      for (final g in all)
        if (keys.contains(g.key)) g,
    ];
    notifyListeners();
  }

  /// The mail of [groups] in the inboxes (any age), that "Archive all"
  /// moves: not pinned mail.
  List<StoredMessage> inboxMail(Iterable<SenderGroup> groups) {
    final accounts = _store.accounts.all();
    final seen = <int>{};
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

  @override
  void dispose() {
    _disposed = true;
    controller.counts.removeListener(_mailChanged);
    super.dispose();
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
