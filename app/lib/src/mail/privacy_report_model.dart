// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../services/app_services.dart';

/// The periods the report covers.
enum PrivacyPeriod {
  week(7, 'Last 7 days', 'in the last 7 days'),
  month(30, 'Last 30 days', 'in the last 30 days');

  const PrivacyPeriod(this.days, this.label, this.phrase);

  final int days;
  final String label;

  /// "in the last 7 days".
  final String phrase;
}

/// The Privacy report's data: what the app kept from senders in mail
/// received lately, counted on the device from the messages whose content
/// is stored. Nothing is downloaded for it and nothing is kept: it is
/// worked out again, off the UI thread, each time the page opens.
final class PrivacyReportModel extends ChangeNotifier {
  PrivacyReportModel(this._services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices _services;
  final DateTime Function() _now;

  MailStore get _store => _services.store;

  /// Messages read for the report at most (the newest).
  static const maxMessages = 3000;

  /// Messages handed to the helper isolate at a time, so their bodies
  /// are not all in memory at once.
  static const _batch = 40;

  bool loading = true;

  /// While counting: how many messages are done, of how many.
  ({int done, int total})? progress;

  PrivacyPeriod period = PrivacyPeriod.week;

  var _reports = const <PrivacyPeriod, PrivacyReport>{};
  var _received = const <PrivacyPeriod, int>{};
  var _capped = const <PrivacyPeriod>{};
  bool _disposed = false;

  PrivacyReport get report => _reports[period] ?? PrivacyReport.empty;

  /// All mail received in the period, downloaded or not.
  int get received => _received[period] ?? 0;

  /// More mail than [maxMessages] is on the device for the period: only
  /// the newest was counted.
  bool get capped => _capped.contains(period);

  void select(PrivacyPeriod value) {
    if (value == period) return;
    period = value;
    notifyListeners();
  }

  Future<void> load() async {
    final now = _now();
    DateTime since(PrivacyPeriod p) => now.subtract(Duration(days: p.days));
    final longest = PrivacyPeriod.values.last;
    final found = _store.messages.downloadedSince(
      since(longest),
      limit: maxMessages,
    );
    final received = {
      for (final p in PrivacyPeriod.values)
        p: p == longest
            ? found.received
            : _store.messages.downloadedSince(since(p), limit: 1).received,
    };

    // What the reader would know besides each message: the account's
    // trusted verification server and the user's domains, and whether the
    // sender's images are always loaded.
    final ownDomains = {
      for (final account in _store.accounts.all())
        ?Domains.registrable(
          account.email.substring(account.email.lastIndexOf('@') + 1),
        ),
    };
    final contexts = <int, TrustContext>{};
    TrustContext context(int accountId) => contexts.putIfAbsent(accountId, () {
      final inbox = _store.mailboxes.inbox(accountId);
      final account = _store.accounts.byId(accountId);
      return TrustContext(
        trustedAuthServId: inbox == null
            ? null
            : AuthServIds.learn(
                _store.messages.firstHeaderValues(
                  inbox.id,
                  'authentication-results',
                ),
                serverHosts: {?account?.imap.host},
              ),
        ownDomains: ownDomains,
      );
    });
    final allowed = <String, bool>{};
    bool imagesAllowed(String? address) => address == null
        ? false
        : allowed.putIfAbsent(
            address.toLowerCase(),
            () => _store.imageSenders.isAllowed(address),
          );

    final messages = found.downloaded;
    final emails = <PrivacyEmail>[];
    progress = (done: 0, total: messages.length);
    notifyListeners();
    for (var start = 0; start < messages.length; start += _batch) {
      final batch = messages.skip(start).take(_batch).toList();
      final inputs = <_Input>[];
      final kept = <StoredMessage>[];
      for (final m in batch) {
        final raw = _store.messages.body(m.id);
        if (raw == null) continue; // removed meanwhile
        kept.add(m);
        inputs.add((raw, context(m.accountId), imagesAllowed(m.from?.address)));
      }
      final results = await compute(_count, inputs);
      if (_disposed) return;
      for (final (i, m) in kept.indexed) {
        if (results[i] case final privacy?) {
          emails.add(
            PrivacyEmail(
              address: m.from?.address ?? '',
              name: m.from?.displayName,
              receivedAt: m.receivedAt,
              privacy: privacy,
            ),
          );
        }
      }
      progress = (done: start + batch.length, total: messages.length);
      notifyListeners();
    }

    _received = received;
    _capped = {
      if (messages.length >= maxMessages)
        for (final p in PrivacyPeriod.values)
          if (messages.last.receivedAt.isAfter(since(p))) p,
    };
    _reports = {
      for (final p in PrivacyPeriod.values)
        p: PrivacyReport.of(emails, since: since(p)),
    };
    progress = null;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

typedef _Input = (Uint8List raw, TrustContext context, bool imagesAllowed);

/// Top level, so [compute] sends only the bytes to the helper isolate.
/// Null for a message that couldn't be read.
List<MessagePrivacy?> _count(List<_Input> inputs) => [
  for (final (raw, context, imagesAllowed) in inputs)
    () {
      try {
        final view = MessageView.parse(raw);
        return MessagePrivacy.of(
          view,
          trust: const TrustChecker().check(view, context),
          imagesAllowed: imagesAllowed,
        );
      } on Object {
        return null;
      }
    }(),
];
