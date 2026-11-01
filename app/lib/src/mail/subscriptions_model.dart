// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../services/app_services.dart';

/// The Subscriptions page's data: paid subscriptions found in receipts and
/// renewal mail, on the device. Prices come from the receipts' text: the
/// preview, or the whole message once downloaded. [readReceipts]
/// downloads the receipts that are not on the device yet, only when the
/// user asks.
final class SubscriptionsModel extends ChangeNotifier {
  SubscriptionsModel(this._services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices _services;
  final DateTime Function() _now;

  MailStore get _store => _services.store;

  static const _hiddenKey = 'subscriptions.hidden';

  /// How far back receipts are looked at.
  static const lookBack = Duration(days: 2 * 366);

  /// Receipts downloaded for prices: the newest few of each subscription,
  /// small ones only.
  static const _perSubscription = 6;
  static const _maxBytes = 512 * 1024;

  bool loading = true;
  List<Subscription> subscriptions = const [];

  /// Companies the user said are not subscriptions.
  Set<String> hidden = const {};
  List<Subscription> hiddenOnes = const [];

  /// Receipts not on the device yet, of subscriptions whose price or
  /// cadence is not known.
  List<int> toRead = const [];

  /// While reading receipts: how many are done, of how many.
  ({int done, int total})? reading;
  bool _stop = false;

  /// Subscriptions charging within a week.
  List<Subscription> get renewingSoon {
    final soon = _now().add(const Duration(days: 7));
    return [
      for (final s in subscriptions)
        if (s.nextCharge case final next? when next.isBefore(soon)) s,
    ];
  }

  List<Subscription> get active => [
    for (final s in subscriptions)
      if (s.status == SubscriptionStatus.active) s,
  ];

  /// What the active subscriptions cost a month, per currency (those with
  /// a known price and cadence).
  Map<String, int> get monthlyTotals {
    final totals = <String, int>{};
    for (final s in active) {
      if (s.monthly case final m?) {
        totals[m.currency] = (totals[m.currency] ?? 0) + m.minor;
      }
    }
    return totals;
  }

  Future<void> load() async {
    hidden = {
      ...?_store.settings
          .read(_hiddenKey)
          ?.split(',')
          .where((s) => s.isNotEmpty),
    };
    final candidates = _store.messages.withSubjectWords(
      SubscriptionFinder.subjectWords,
      since: _now().subtract(lookBack),
    );
    // Message text off the UI thread: downloaded bodies are parsed.
    final texts = await compute(_texts, [
      for (final m in candidates) (_store.messages.body(m.id), m.snippet),
    ]);
    final emails = <SubscriptionEmail>[
      for (final (i, m) in candidates.indexed)
        if (m.from case final from?)
          SubscriptionEmail(
            messageId: m.id,
            company:
                Domains.registrable(from.domain) ?? from.domain.toLowerCase(),
            senderName: from.displayName,
            subject: m.subject ?? '',
            text: texts[i],
            at: m.receivedAt,
          ),
    ];
    final all = SubscriptionFinder.find(emails, now: _now());
    subscriptions = [
      for (final s in all)
        if (!hidden.contains(s.company)) s,
    ];
    hiddenOnes = [
      for (final s in all)
        if (hidden.contains(s.company)) s,
    ];
    final sizes = {for (final m in candidates) m.id: m.size};
    // Only where something is missing: no price, or no "how often".
    toRead = [
      for (final s in subscriptions)
        if (s.amount == null || s.cadence == null)
          for (final r
              in s.records
                  .where(
                    (r) =>
                        _store.messages.body(r.email.messageId) == null &&
                        (sizes[r.email.messageId] ?? 0) <= _maxBytes,
                  )
                  .take(_perSubscription))
            r.email.messageId,
    ];
    loading = false;
    notifyListeners();
  }

  /// Downloads the receipts in [toRead] from the user's own mail server
  /// (they stay unread), then looks again. Stops early on [stopReading].
  Future<void> readReceipts() async {
    if (reading != null || toRead.isEmpty) return;
    final ids = toRead;
    _stop = false;
    var done = 0;
    reading = (done: 0, total: ids.length);
    notifyListeners();
    for (final id in ids) {
      if (_stop) break;
      try {
        await _services.worker.loadBody(id);
      } on Object {
        // Gone, too large or offline: its price stays unknown.
      }
      reading = (done: ++done, total: ids.length);
      notifyListeners();
    }
    reading = null;
    await load();
  }

  void stopReading() => _stop = true;

  /// "Not a subscription": hidden from the list (undoable).
  void hide(String company) => _setHidden({...hidden, company});

  void unhide(String company) => _setHidden({...hidden}..remove(company));

  void _setHidden(Set<String> companies) {
    _store.settings.write(_hiddenKey, companies.join(','));
    unawaited(load());
  }

  StoredMessage? message(int id) => _store.messages.byId(id);
}

/// Each message's text: the downloaded body when there is one (capped),
/// else its preview.
List<String> _texts(List<(Uint8List?, String?)> messages) => [
  for (final (raw, snippet) in messages)
    if (raw != null)
      () {
        final text = MessageView.parse(raw).body.plainText;
        return text.length > 20000 ? text.substring(0, 20000) : text;
      }()
    else
      snippet ?? '',
];
