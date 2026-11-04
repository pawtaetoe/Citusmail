// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'due_dates.dart';
import 'subscriptions.dart';

/// What a reminder is about.
enum ReminderKind {
  /// A bill to pay by a date.
  billDue,

  /// A free trial that ends (and starts charging).
  trialEnds,

  /// A subscription that charges again.
  renewal,
}

/// Something coming up that the mail speaks of: a bill due, a free trial
/// ending, a renewal.
final class Reminder {
  const Reminder({
    required this.kind,
    required this.company,
    required this.name,
    required this.date,
    required this.messageId,
    this.amount,
    this.cadence,
  });

  final ReminderKind kind;

  /// The sender's registrable domain.
  final String company;

  /// What to call it: "MyRepublic", "pandapro", "Spotify".
  final String name;

  /// The day it is due, the trial ends or the subscription renews
  /// (a calendar day, midnight UTC).
  final DateTime date;

  /// The email to open: the bill, the trial email, the last receipt.
  final int messageId;

  /// What is due, what the trial becomes, what the renewal charges.
  final Money? amount;

  /// For a trial: how often its price charges ("then S$59.88 a year").
  /// For a renewal: the subscription's.
  final Cadence? cadence;

  /// Identifies this reminder (to dismiss it, or to notify once): a new
  /// bill or another date is another reminder.
  String get key {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${kind.name}:$company:'
        '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  /// Days from [now]'s calendar day to [date]: 0 today, negative when
  /// past.
  int daysFrom(DateTime now) => date.difference(DueDates.dayOf(now)).inDays;
}

/// Finds bills due, free trials ending and renewals coming up, from the
/// same emails as [SubscriptionFinder], on the device.
abstract final class Reminders {
  /// Bills and trials this many days ahead are shown.
  static const billDays = 14;

  /// Renewals this many days ahead.
  static const renewalDays = 7;

  /// A bill stays this many days after its due date (it may not be paid).
  static const overdueDays = 3;

  static final _billSubject = RegExp(
    r'\b(?:e-?bills?|bills?|invoices?|amount due|payment due|'
    r'payment reminder|due (?:soon|date|today|tomorrow)|is due|'
    r'outstanding)\b',
    caseSensitive: false,
  );

  /// A payment made: the bill is paid.
  static final _paidSubject = RegExp(
    r'\b(?:payment (?:received|successful|confirmation|confirmed|'
    r'acknowledg\w*)|successful(?:ly)? (?:payment|paid)|'
    r'payment (?:was|has been) (?:successful|received)|'
    r'thank(?:s| you) for (?:your )?payment|receipt|paid)\b',
    caseSensitive: false,
  );

  /// The bill itself says it is paid.
  static final _paidText = RegExp(
    r'\b(?:amount paid|has been paid|paid in full|no payment (?:is )?required|'
    r'nothing to pay)\b',
    caseSensitive: false,
  );

  static final _failed = RegExp(
    r'\b(?:unsuccessful|failed|declined|unable)\b',
    caseSensitive: false,
  );

  /// Whether [email] may be a bill to pay (its subject says so, and it is
  /// not a receipt, an account statement or a discussion). Whether it
  /// says when it is due is another matter: [DueDates.dueDateIn].
  static bool mayBeBill(SubscriptionEmail email) {
    final subject = email.subject;
    if (SubscriptionFinder.isReplyOrForward(subject)) return false;
    if (SubscriptionFinder.isAccountStatement(subject)) return false;
    if (!_billSubject.hasMatch(subject)) return false;
    if (_paidSubject.hasMatch(subject) && !_failed.hasMatch(subject)) {
      return false;
    }
    return SubscriptionFinder.eventOf(email) != SubscriptionEvent.trial;
  }

  /// Whether [email] is about a free trial.
  static bool isTrial(SubscriptionEmail email) =>
      !SubscriptionFinder.isReplyOrForward(email.subject) &&
      SubscriptionFinder.eventOf(email) == SubscriptionEvent.trial;

  static bool _isPayment(SubscriptionEmail email) =>
      !SubscriptionFinder.isReplyOrForward(email.subject) &&
      _paidSubject.hasMatch(email.subject) &&
      !_failed.hasMatch(email.subject);

  /// What is coming up in [emails] (any order), soonest first: bills due
  /// within [billDays] (or up to [overdueDays] late), trials ending within
  /// [billDays], and renewals of [subscriptions] within [renewalDays]
  /// (those found in the same emails by [SubscriptionFinder.find]).
  /// Renewals are yearly and quarterly ones, and monthly and weekly ones
  /// too with [monthlyRenewals]; none of a company in [hidden] (not a
  /// subscription). [now] is now.
  static List<Reminder> find(
    Iterable<SubscriptionEmail> emails, {
    required List<Subscription> subscriptions,
    required DateTime now,
    bool monthlyRenewals = false,
    Set<String> hidden = const {},
  }) {
    final today = DueDates.dayOf(now);
    final list = [...emails]..sort((a, b) => b.at.compareTo(a.at));
    final found = <Reminder>[..._bills(list, today), ..._trials(list, today)];
    final billed = {for (final r in found) r.company};
    for (final s in subscriptions) {
      final next = s.nextCharge;
      final cadence = s.cadence;
      if (next == null ||
          cadence == null ||
          s.status != SubscriptionStatus.active ||
          s.variable ||
          hidden.contains(s.company) ||
          billed.contains(s.company)) {
        continue;
      }
      if (!monthlyRenewals &&
          (cadence == Cadence.monthly || cadence == Cadence.weekly)) {
        continue;
      }
      final day = DueDates.dayOf(next);
      final days = day.difference(today).inDays;
      if (days < 0 || days > renewalDays) continue;
      final receipt = s.records
          .where((r) => r.event == SubscriptionEvent.charge)
          .firstOrNull;
      found.add(
        Reminder(
          kind: ReminderKind.renewal,
          company: s.company,
          name: s.name,
          date: day,
          messageId: (receipt ?? s.records.first).email.messageId,
          amount: s.amount,
          cadence: cadence,
        ),
      );
    }
    found.sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.kind.index.compareTo(b.kind.index);
    });
    return found;
  }

  /// Each company's newest bill, when it says when it's due, is not paid
  /// yet and is due soon.
  static Iterable<Reminder> _bills(
    List<SubscriptionEmail> newestFirst,
    DateTime today,
  ) sync* {
    final seen = <String>{};
    for (final bill in newestFirst) {
      if (!mayBeBill(bill) || !seen.add(bill.company)) continue;
      if (today.difference(DueDates.dayOf(bill.at)).inDays > 90) continue;
      final text = '${bill.subject}\n${bill.text}';
      if (_paidText.hasMatch(text)) continue;
      final due = DueDates.dueDateIn(text, received: bill.at);
      if (due == null) continue;
      final days = due.difference(today).inDays;
      if (days < -overdueDays || days > billDays) continue;
      // A payment to the same company after the bill covers it.
      final paid = newestFirst.any(
        (e) => e.at.isAfter(bill.at) && _sameSender(e, bill) && _isPayment(e),
      );
      if (paid) continue;
      yield Reminder(
        kind: ReminderKind.billDue,
        company: bill.company,
        name: _senderName(bill),
        date: due,
        messageId: bill.messageId,
        amount: _amountDue(text),
      );
    }
  }

  static bool _sameSender(SubscriptionEmail a, SubscriptionEmail b) {
    if (a.company == b.company) return true;
    final x = a.senderName?.trim().toLowerCase();
    final y = b.senderName?.trim().toLowerCase();
    return x != null && x.isNotEmpty && x == y;
  }

  static String _senderName(SubscriptionEmail email) {
    final name = email.senderName?.trim();
    return name == null || name.isEmpty ? email.company : name;
  }

  static final _dueAmountWords = RegExp(
    r'\b(?:outstanding|amount (?:due|payable)|total (?:amount )?due|'
    r'balance (?:due|payable)|to pay|please pay|pay(?:able)?|due)\b',
    caseSensitive: false,
  );

  /// The amount to pay: one shortly after "outstanding amount", "amount
  /// due"...; else the amount the bill shows as its total.
  static Money? _amountDue(String text) {
    for (final a in SubscriptionFinder.amountsIn(text)) {
      final before = text.substring(
        a.start - 60 < 0 ? 0 : a.start - 60,
        a.start,
      );
      if (_dueAmountWords.hasMatch(before)) return a.money;
    }
    return SubscriptionFinder.amountIn(text);
  }

  /// A trial's product name in its subject: "Your pandapro free trial has
  /// started" -> pandapro.
  static final _product = RegExp(
    r'\byour\s+(\S.{0,30}?)\s+(?:free\s+)?trial\b',
    caseSensitive: false,
  );

  /// Words before the price a trial turns into.
  static final _thenWords = RegExp(
    r'\b(?:then|after(?:wards)?|thereafter|will be|renews? at|'
    r'auto-?renews? at|continue(?:s)? at|charged|billed|only|just)\b'
    r'[^.\n]{0,25}$',
    caseSensitive: false,
  );

  static final _afterTrial = RegExp(
    r'^[^.\n]{0,40}\b(?:after|when|once)\b[^.\n]{0,20}\btrial\b',
    caseSensitive: false,
  );

  static final _per = RegExp(
    r'^\s*(?:/\s*|(?:a|an|per|every|each)\s+)?'
    r'(year|yr|annum|annually|yearly|month|mo|monthly|week|wk|weekly|quarter)\b',
    caseSensitive: false,
  );

  /// The price [text] says a trial turns into ("then S$59.88/year"), and
  /// how often.
  static ({Money money, Cadence? cadence})? _priceAfterTrial(String text) {
    for (final a in SubscriptionFinder.amountsIn(text)) {
      final before = text.substring(
        a.start - 40 < 0 ? 0 : a.start - 40,
        a.start,
      );
      final after = text.substring(
        a.end,
        a.end + 60 > text.length ? text.length : a.end + 60,
      );
      if (!_thenWords.hasMatch(before) && !_afterTrial.hasMatch(after)) {
        continue;
      }
      final per = _per.firstMatch(after)?[1]?.toLowerCase();
      final cadence = switch (per) {
        null => null,
        'week' || 'wk' || 'weekly' => Cadence.weekly,
        'month' || 'mo' || 'monthly' => Cadence.monthly,
        'quarter' => Cadence.quarterly,
        _ => Cadence.yearly,
      };
      return (money: a.money, cadence: cadence);
    }
    return null;
  }

  /// Each company's current free trial, when its end is known, it hasn't
  /// charged or been cancelled since, and it ends soon.
  static Iterable<Reminder> _trials(
    List<SubscriptionEmail> newestFirst,
    DateTime today,
  ) sync* {
    final byCompany = <String, List<SubscriptionEmail>>{};
    for (final e in newestFirst) {
      if (isTrial(e)) byCompany.putIfAbsent(e.company, () => []).add(e);
    }
    for (final MapEntry(key: company, value: trial) in byCompany.entries) {
      final newest = trial.first;
      // This trial's emails: those within a few months of the newest.
      final run = [
        for (final e in trial)
          if (newest.at.difference(e.at).inDays <= 120) e,
      ];
      final started = run.last.at;
      // A charge for it or a cancellation since: no longer a trial (a
      // food order from the same company is not that charge).
      var charged = false;
      var cancelled = false;
      for (final e in newestFirst) {
        if (e.company != company ||
            !e.at.isAfter(started) ||
            SubscriptionFinder.isReplyOrForward(e.subject)) {
          continue;
        }
        switch (SubscriptionFinder.eventOf(e)) {
          case SubscriptionEvent.charge
              when SubscriptionFinder.speaksOfSubscription(e):
            charged = true;
          case SubscriptionEvent.cancelled:
            cancelled = true;
          case _:
        }
      }
      if (charged || cancelled) continue;
      DateTime? end;
      ({Money money, Cadence? cadence})? price;
      String? product;
      for (final e in run) {
        final text = '${e.subject}\n${e.text}';
        end ??= DueDates.trialEndIn(text, received: e.at);
        price ??= _priceAfterTrial(text);
        product ??= _productIn(e.subject);
      }
      if (end == null) continue;
      final days = end.difference(today).inDays;
      if (days < 0 || days > billDays) continue;
      yield Reminder(
        kind: ReminderKind.trialEnds,
        company: company,
        name: product ?? _senderName(newest),
        date: end,
        messageId: newest.messageId,
        amount: price?.money,
        cadence: price?.cadence,
      );
    }
  }

  static String? _productIn(String subject) {
    final name = _product.firstMatch(subject)?[1]?.trim();
    if (name == null) return null;
    const notNames = {'free', 'trial', 'subscription', 'membership'};
    return notNames.contains(name.toLowerCase()) ? null : name;
  }
}
