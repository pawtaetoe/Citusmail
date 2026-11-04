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
import '../services/reminders.dart';
import 'corrections.dart';

/// The mail subscriptions and reminders are read from: receipts, bills,
/// renewal and trial emails of the last two years.
typedef SubscriptionMail = ({
  List<StoredMessage> messages,
  List<SubscriptionEmail> emails,
});

/// Picks the mail [SubscriptionFinder] and [Reminders] look at from
/// [store], and reads its text off the UI thread (downloaded bodies are
/// parsed; else the preview).
Future<SubscriptionMail> loadSubscriptionMail(
  MailStore store,
  DateTime now,
) async {
  final candidates = store.messages.withSubjectWords(
    SubscriptionFinder.subjectWords,
    since: now.subtract(SubscriptionsModel.lookBack),
  );
  final texts = await compute(_texts, [
    for (final m in candidates) (store.messages.body(m.id), m.snippet),
  ]);
  return (
    messages: candidates,
    emails: <SubscriptionEmail>[
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
    ],
  );
}

/// The companies the user said are not subscriptions.
Set<String> hiddenSubscriptions(MailStore store) => {
  ...?store.settings
      .read(SubscriptionsModel.hiddenKey)
      ?.split(',')
      .where((s) => s.isNotEmpty),
};

/// The companies whose subscription is left out because it looks like
/// ones the user said are not subscriptions ([Corrections]); [found] by
/// the rules in [mail], those in [hidden] aside.
Future<Set<String>> learnedNotSubscriptions(
  MailStore store,
  SubscriptionMail mail,
  List<Subscription> found,
  Set<String> hidden,
) {
  final messages = {for (final m in mail.messages) m.id: m};
  return Corrections(store).vetoed(MailKind.subscription, {
    for (final s in found)
      if (!hidden.contains(s.company))
        s.company: subscriptionSamples(s, (id) => messages[id]),
  });
}

/// What the classifier reads of [subscription]'s emails.
List<MailSample> subscriptionSamples(
  Subscription subscription,
  StoredMessage? Function(int id) message,
) => [
  for (final r in subscription.records)
    mailSample(
      message(r.email.messageId),
      domain: subscription.company,
      senderName: r.email.senderName,
      subject: r.email.subject,
      text: r.email.text,
    ),
];

/// The Subscriptions page's data: paid subscriptions found in receipts and
/// renewal mail, and what is coming up (bills due, free trials ending,
/// renewals), on the device. Prices and dates come from the emails' text:
/// the preview, or the whole message once downloaded. [readReceipts]
/// downloads the receipts and bills that are not on the device yet, only
/// when the user asks.
final class SubscriptionsModel extends ChangeNotifier {
  SubscriptionsModel(this._services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices _services;
  final DateTime Function() _now;

  MailStore get _store => _services.store;

  static const hiddenKey = 'subscriptions.hidden';

  /// How far back receipts are looked at.
  static const lookBack = Duration(days: 2 * 366);

  /// Receipts downloaded for prices: the newest few of each subscription,
  /// small ones only.
  static const _perSubscription = 6;
  static const _maxBytes = 512 * 1024;

  /// Receipts of companies not recognised yet, downloaded at most.
  static const _unknownMax = 30;

  /// Bills and trial emails this recent are downloaded for their dates.
  static const _datesBack = Duration(days: 45);

  bool loading = true;
  List<Subscription> subscriptions = const [];

  /// Companies the user said are not subscriptions.
  Set<String> hidden = const {};

  /// Companies left out because they look like ones the user said are
  /// not subscriptions ("Learn from my corrections").
  Set<String> learned = const {};

  /// Those of [hidden] and [learned].
  List<Subscription> hiddenOnes = const [];

  /// Everything the rules found.
  List<Subscription> _all = const [];

  late final _corrections = Corrections(_store);

  /// Bills due, free trials ending and renewals in the next days, soonest
  /// first, except those the user dismissed.
  List<Reminder> comingUp = const [];

  /// Receipts not on the device yet, of subscriptions whose price or
  /// cadence is not known, and recent bills and trial emails whose date
  /// is not known.
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

  Future<void> load() async {
    hidden = hiddenSubscriptions(_store);
    final now = _now();
    final (messages: candidates, :emails) = await loadSubscriptionMail(
      _store,
      now,
    );
    final all = SubscriptionFinder.find(emails, now: now);
    _all = all;
    learned = await learnedNotSubscriptions(
      _store,
      (messages: candidates, emails: emails),
      all,
      hidden,
    );
    final left = {...hidden, ...learned};
    final dismissed = ReminderState(_store).dismissed;
    final reminders = Reminders.find(
      emails,
      subscriptions: all,
      now: now,
      monthlyRenewals: _services.settings.monthlyRenewals,
      hidden: left,
    );
    comingUp = [
      for (final r in reminders)
        if (!dismissed.contains(r.key)) r,
    ];
    subscriptions = [
      for (final s in all)
        if (!left.contains(s.company)) s,
    ];
    hiddenOnes = [
      for (final s in all)
        if (left.contains(s.company)) s,
    ];
    final sizes = {for (final m in candidates) m.id: m.size};
    // Bills and trials whose date is known need nothing more.
    final dated = {
      for (final r in reminders)
        if (r.kind != ReminderKind.renewal) r.company,
    };
    toRead = {
      // Only where something is missing: no price, or no "how often".
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
      // Receipts of companies not recognised yet: their whole text may
      // show a billing period ("Sep 28, 2026 – Sep 28, 2027").
      ..._unknownReceipts(emails, all, sizes),
      // Recent bills and trial emails: their whole text may say when
      // they're due or end.
      for (final e in emails)
        if (now.difference(e.at) < _datesBack &&
            !dated.contains(e.company) &&
            (Reminders.mayBeBill(e) || Reminders.isTrial(e)) &&
            _store.messages.body(e.messageId) == null &&
            (sizes[e.messageId] ?? 0) <= _maxBytes)
          e.messageId,
    }.toList();
    loading = false;
    notifyListeners();
  }

  /// Receipts not on the device, newest first, from companies that are
  /// neither listed nor hidden.
  Iterable<int> _unknownReceipts(
    List<SubscriptionEmail> emails,
    List<Subscription> found,
    Map<int, int> sizes,
  ) {
    final known = {for (final s in found) s.company};
    final receipts = [
      for (final e in emails)
        if (!known.contains(e.company) &&
            !hidden.contains(e.company) &&
            !learned.contains(e.company) &&
            !SubscriptionFinder.isReplyOrForward(e.subject) &&
            SubscriptionFinder.eventOf(e) == SubscriptionEvent.charge &&
            _store.messages.body(e.messageId) == null &&
            (sizes[e.messageId] ?? 0) <= _maxBytes)
          e,
    ]..sort((a, b) => b.at.compareTo(a.at));
    return receipts.take(_unknownMax).map((e) => e.messageId);
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

  /// "Not a subscription": hidden from the list (undoable), and learned
  /// from.
  void hide(String company) {
    if (_found(company) case final s?) {
      _corrections.rejected(MailKind.subscription, _samples(s));
    }
    _setHidden({...hidden, company});
  }

  /// Undo, or "List again": listed again (and never left out by
  /// learning again).
  void unhide(String company) {
    final s = _found(company);
    if (hidden.contains(company)) {
      if (s != null) {
        _corrections.rejected(MailKind.subscription, _samples(s), undo: true);
      }
      _setHidden({...hidden}..remove(company));
    } else if (learned.contains(company)) {
      _corrections.kept(
        MailKind.subscription,
        company,
        s == null ? const [] : _samples(s),
      );
      unawaited(load());
    }
  }

  /// [subscription]'s page was opened: a weak sign that it is one.
  void opened(Subscription subscription) => _corrections.opened(
    MailKind.subscription,
    subscription.company,
    _samples(subscription),
  );

  Subscription? _found(String company) =>
      _all.where((s) => s.company == company).firstOrNull;

  List<MailSample> _samples(Subscription s) =>
      subscriptionSamples(s, _store.messages.byId);

  void _setHidden(Set<String> companies) {
    _store.settings.write(hiddenKey, companies.join(','));
    unawaited(load());
  }

  /// "Done" or "Not needed": [reminder] is no longer shown or notified
  /// (undoable).
  void dismiss(Reminder reminder) {
    ReminderState(_store).dismiss(reminder.key);
    comingUp = [
      for (final r in comingUp)
        if (r.key != reminder.key) r,
    ];
    notifyListeners();
  }

  void undismiss(Reminder reminder) {
    ReminderState(_store).undismiss(reminder.key);
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
