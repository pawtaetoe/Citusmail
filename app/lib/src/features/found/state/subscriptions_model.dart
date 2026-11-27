// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';

import '../../../services/reminders.dart';
import '../../../services/store_reader.dart';
import '../../inbox/state/corrections.dart';
import '../../inbox/state/message_reads.dart';
import 'found_model.dart';

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
  final texts = await plainTextReads.read(store, candidates);
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
  ...SubscriptionsModel.hiddenSetting.read(store.settings),
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
  StoredMessage? Function(MessageId id) message,
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

/// What [findSubscriptions] found: every subscription the rules found
/// ([hidden] and [learned] ones too), what is coming up (those of hidden
/// and learned companies aside; dismissed ones still in), and the emails
/// worth downloading ([toRead]).
typedef SubscriptionsFound = ({
  List<Subscription> all,
  Set<String> hidden,
  Set<String> learned,
  List<Reminder> reminders,
  List<MessageId> toRead,
});

/// The Subscriptions page's findings in [store], reading text off the UI
/// thread. The page and reading in the background both use it, so both
/// want the same emails. [toRead] leaves out [skip].
Future<SubscriptionsFound> findSubscriptions(
  MailStore store,
  DateTime now, {
  required bool monthlyRenewals,
  Set<MessageId> skip = const {},
}) async {
  final hidden = hiddenSubscriptions(store);
  final mail = await loadSubscriptionMail(store, now);
  final all = SubscriptionFinder.find(mail.emails, now: now);
  final learned = await learnedNotSubscriptions(store, mail, all, hidden);
  final left = {...hidden, ...learned};
  final reminders = Reminders.find(
    mail.emails,
    subscriptions: all,
    now: now,
    monthlyRenewals: monthlyRenewals,
    hidden: left,
  );
  return (
    all: all,
    hidden: hidden,
    learned: learned,
    reminders: reminders,
    toRead: subscriptionMailToRead(
      store,
      mail,
      now: now,
      found: all,
      left: left,
      reminders: reminders,
      skip: skip,
    ),
  );
}

/// The emails of [mail] not on the device yet whose whole text may fill
/// in the Subscriptions page: receipts of subscriptions ([found], those in
/// [left] aside) whose price or cadence is not known, receipts of
/// companies not recognised yet, and recent bills and trial emails whose
/// date is not known ([reminders]). Small ones only, at most a few per
/// subscription; [skip] left out.
List<MessageId> subscriptionMailToRead(
  MailStore store,
  SubscriptionMail mail, {
  required DateTime now,
  required List<Subscription> found,
  required Set<String> left,
  required List<Reminder> reminders,
  Set<MessageId> skip = const {},
}) {
  final sizes = {for (final m in mail.messages) m.id: m.size};
  bool wanted(MessageId id) =>
      !skip.contains(id) &&
      !MessageReads.downloaded(store, id) &&
      (sizes[id] ?? 0) <= SubscriptionsModel.maxBytes;
  // Bills and trials whose date is known need nothing more.
  final dated = {
    for (final r in reminders)
      if (r.kind != ReminderKind.renewal) r.company,
  };
  // Receipts not on the device, newest first, from companies that are
  // neither listed nor hidden: their whole text may show a billing period
  // ("Sep 28, 2026 – Sep 28, 2027").
  final known = {for (final s in found) s.company};
  final unknown = [
    for (final e in mail.emails)
      if (!known.contains(e.company) &&
          !left.contains(e.company) &&
          !SubscriptionFinder.isReplyOrForward(e.subject) &&
          SubscriptionFinder.eventOf(e) == SubscriptionEvent.charge &&
          wanted(e.messageId))
        e,
  ]..sort((a, b) => b.at.compareTo(a.at));
  return {
    // Only where something is missing: no price, or no "how often".
    for (final s in found)
      if (!left.contains(s.company) && (s.amount == null || s.cadence == null))
        for (final r
            in s.records
                .where((r) => wanted(r.email.messageId))
                .take(SubscriptionsModel.perSubscription))
          r.email.messageId,
    for (final e in unknown.take(SubscriptionsModel.unknownMax)) e.messageId,
    // Recent bills and trial emails: their whole text may say when they're
    // due or end.
    for (final e in mail.emails)
      if (now.difference(e.at) < SubscriptionsModel.datesBack &&
          !dated.contains(e.company) &&
          (Reminders.mayBeBill(e) || Reminders.isTrial(e)) &&
          wanted(e.messageId))
        e.messageId,
  }.toList();
}

/// The Subscriptions page's findings, with what is coming up that the
/// user has not dismissed.
typedef SubscriptionsPage = ({
  SubscriptionsFound found,
  List<Reminder> comingUp,
});

/// The Subscriptions page's data: paid subscriptions found in receipts and
/// renewal mail, and what is coming up (bills due, free trials ending,
/// renewals), on the device. Prices and dates come from the emails' text:
/// the preview, or the whole message once downloaded. [readEmails]
/// downloads the receipts and bills that are not on the device yet, only
/// when the user asks.
/// [findSubscriptions] as a [StoreTask], off the UI isolate.
StoreTask<SubscriptionsFound> _subscriptionsTask(
  DateTime now,
  Set<MessageId> skip,
  bool monthlyRenewals,
) =>
    (store) => findSubscriptions(
      store,
      now,
      monthlyRenewals: monthlyRenewals,
      skip: skip,
    );

final class SubscriptionsModel
    extends FoundModel<Subscription, SubscriptionsPage> {
  SubscriptionsModel(super.services, {super.now})
    : super(kind: MailKind.subscription, hiddenKeys: hiddenSetting);

  static const hiddenSetting = StringListSetting('subscriptions.hidden');

  /// How far back receipts are looked at.
  static const lookBack = Duration(days: 2 * 366);

  /// Receipts downloaded for prices: the newest few of each subscription,
  /// small ones only.
  static const perSubscription = 6;
  static const maxBytes = 512 * 1024;

  /// Receipts of companies not recognised yet, downloaded at most.
  static const unknownMax = 30;

  /// Bills and trial emails this recent are downloaded for their dates.
  static const datesBack = Duration(days: 45);

  @override
  Future<SubscriptionsPage> find(DateTime now, Set<MessageId> skip) async {
    final found = await services.reads.run(
      _subscriptionsTask(now, skip, services.settings.monthlyRenewals),
    );
    final dismissed = ReminderState(store).dismissed;
    return (
      found: found,
      comingUp: [
        for (final r in found.reminders)
          if (!dismissed.contains(r.key)) r,
      ],
    );
  }

  @override
  Finds<Subscription> findsOf(SubscriptionsPage page) => (
    all: page.found.all,
    hidden: page.found.hidden,
    learned: page.found.learned,
    toRead: page.found.toRead,
  );

  @override
  String keyOf(Subscription item) => item.company;

  @override
  List<MailSample> samplesOf(Subscription item) =>
      subscriptionSamples(item, store.messages.byId);

  /// The subscriptions listed: those not hidden.
  List<Subscription> get subscriptions => listed;

  /// Bills due, free trials ending and renewals in the next days, soonest
  /// first, except those the user dismissed.
  List<Reminder> get comingUp => found?.comingUp ?? const [];

  /// Subscriptions charging within a week.
  List<Subscription> get renewingSoon {
    final soon = now().add(const Duration(days: 7));
    return [
      for (final s in subscriptions)
        if (s.nextCharge case final next? when next.isBefore(soon)) s,
    ];
  }

  List<Subscription> get active => [
    for (final s in subscriptions)
      if (s.status == SubscriptionStatus.active) s,
  ];

  /// "Done" or "Not needed": [reminder] is no longer shown or notified
  /// (undoable).
  void dismiss(Reminder reminder) {
    ReminderState(store).dismiss(reminder.key);
    if (data case final page?) {
      change(
        page.withFound((
          found: page.found.found,
          comingUp: [
            for (final r in page.found.comingUp)
              if (r.key != reminder.key) r,
          ],
        )),
      );
    }
  }

  void undismiss(Reminder reminder) {
    ReminderState(store).undismiss(reminder.key);
    unawaited(load());
  }
}
