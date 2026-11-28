// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import 'due_dates.dart';

/// One email that may be about a paid subscription: a receipt, a renewal
/// notice, a cancellation.
final class SubscriptionEmail {
  const SubscriptionEmail({
    required this.messageId,
    required this.company,
    required this.senderName,
    required this.subject,
    required this.text,
    required this.at,
  });

  /// The stored message, to open it.
  final MessageId messageId;

  /// Who charges: the sender's registrable domain (`netflix.com`).
  final String company;

  /// The sender's display name, if any ("Netflix").
  final String? senderName;
  final String subject;

  /// What is known of the body: the preview, or the whole text once the
  /// message was downloaded. May be empty.
  final String text;
  final DateTime at;

  /// Who it is from, as a [Subscription] is keyed: [company], or the
  /// merchant for a payment service's or an app store's mail (`Acme via
  /// stripe.com`, `Acme via Google Play`).
  String get biller =>
      SubscriptionFinder.storeMerchantOf(company, subject, text) ??
      SubscriptionFinder.billerOf(company, senderName);
}

/// How often a subscription charges, roughly (see [BillingPeriod] for
/// the exact period, such as every 30 days).
enum Cadence {
  weekly(7),
  monthly(30),
  quarterly(91),
  halfYearly(182),
  yearly(365);

  const Cadence(this.days);

  /// The usual number of days between charges.
  final int days;

  /// Charges per month, for a monthly total.
  double get perMonth => switch (this) {
    weekly => 52 / 12,
    monthly => 1,
    quarterly => 1 / 3,
    halfYearly => 1 / 6,
    yearly => 1 / 12,
  };

  Duration get period => Duration(days: days);

  /// [n] periods after [from], on the calendar: a bill on the 29th comes
  /// again on the 29th (or the month's last day), not 30 days later.
  DateTime after(DateTime from, [int n = 1]) =>
      BillingPeriod.of(this).after(from, n);
}

/// What a [BillingPeriod] counts in.
enum PeriodUnit { day, week, month, year }

/// The exact time between charges: a calendar period ("monthly", "every
/// 6 months") or a fixed number of days ("every 30 days", which drifts
/// against the calendar).
final class BillingPeriod {
  const BillingPeriod(this.count, this.unit);

  const BillingPeriod.days(int n) : this(n, PeriodUnit.day);

  const BillingPeriod.months(int n) : this(n, PeriodUnit.month);

  final int count;
  final PeriodUnit unit;

  static const weekly = BillingPeriod(1, PeriodUnit.week);
  static const monthly = BillingPeriod.months(1);
  static const quarterly = BillingPeriod.months(3);
  static const halfYearly = BillingPeriod.months(6);
  static const yearly = BillingPeriod.months(12);

  /// The calendar period of [cadence].
  static BillingPeriod of(Cadence cadence) => switch (cadence) {
    Cadence.weekly => weekly,
    Cadence.monthly => monthly,
    Cadence.quarterly => quarterly,
    Cadence.halfYearly => halfYearly,
    Cadence.yearly => yearly,
  };

  /// Calendar months in it, or null for a period of days or weeks.
  int? get months => switch (unit) {
    PeriodUnit.month => count,
    PeriodUnit.year => 12 * count,
    _ => null,
  };

  /// Its length in days (on average, for months).
  int get days => switch (unit) {
    PeriodUnit.day => count,
    PeriodUnit.week => 7 * count,
    PeriodUnit.month => (count * 30.44).round(),
    PeriodUnit.year => 365 * count,
  };

  Duration get length => Duration(days: days);

  /// The [Cadence] it is, or is close to (every 30 days is about
  /// monthly); null for one in between (every 2 months).
  Cadence? get cadence {
    if (months case final m?) {
      return switch (m) {
        1 => Cadence.monthly,
        3 => Cadence.quarterly,
        6 => Cadence.halfYearly,
        12 => Cadence.yearly,
        _ => null,
      };
    }
    return switch (days) {
      >= 6 && <= 8 => Cadence.weekly,
      >= 26 && <= 32 => Cadence.monthly,
      >= 84 && <= 95 => Cadence.quarterly,
      >= 175 && <= 190 => Cadence.halfYearly,
      >= 355 && <= 370 => Cadence.yearly,
      _ => null,
    };
  }

  /// Charges per month, for a monthly total.
  double get perMonth {
    if (months case final m?) return 1 / m;
    if (unit == PeriodUnit.week && count == 1) return Cadence.weekly.perMonth;
    return 365 / 12 / days;
  }

  /// [n] periods after [from]: on the calendar for months and years (a
  /// bill on the 31st comes again on the month's last day), else a fixed
  /// number of days later.
  DateTime after(DateTime from, [int n = 1]) {
    final m = months;
    if (m == null) return from.add(Duration(days: days * n));
    final first = from.isUtc
        ? DateTime.utc(from.year, from.month + m * n)
        : DateTime(from.year, from.month + m * n);
    final last = DateTime.utc(first.year, first.month + 1, 0).day;
    final day = from.day > last ? last : from.day;
    return from.isUtc
        ? DateTime.utc(first.year, first.month, day, from.hour, from.minute)
        : DateTime(first.year, first.month, day, from.hour, from.minute);
  }

  /// How it reads: "Monthly", "Every 30 days", "Every 6 months".
  String get label {
    if (months case final m?) {
      return switch (m) {
        1 => 'Monthly',
        12 => 'Yearly',
        _ when m % 12 == 0 => 'Every ${m ~/ 12} years',
        _ => 'Every $m months',
      };
    }
    if (days == 7) return 'Weekly';
    if (unit == PeriodUnit.week) return 'Every $count weeks';
    return 'Every $count days';
  }

  @override
  bool operator ==(Object other) =>
      other is BillingPeriod && other.count == count && other.unit == unit;

  @override
  int get hashCode => Object.hash(count, unit);

  @override
  String toString() => label;
}

/// A price: [minor] units (cents) of [currency] (`SGD`, `USD`... or the
/// symbol when it alone is ambiguous, such as `$`).
final class Money implements Comparable<Money> {
  const Money(this.minor, this.currency);

  final int minor;
  final String currency;

  @override
  int compareTo(Money other) => minor.compareTo(other.minor);

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() =>
      '$currency ${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')}';
}

/// What an email says about the subscription.
enum SubscriptionEvent {
  /// A payment: receipt, invoice, renewal done.
  charge,

  /// A trial started or is ending.
  trial,

  /// The subscription was cancelled or ends.
  cancelled,

  /// About the subscription, no payment (a renewal reminder...).
  notice,
}

enum SubscriptionStatus {
  active,

  /// No charge for well over a period: probably ended.
  lapsed,

  /// A cancellation came after the last charge.
  cancelled,
}

/// One email, as understood.
final class SubscriptionRecord {
  const SubscriptionRecord(this.email, this.event, this.amount);

  final SubscriptionEmail email;
  final SubscriptionEvent event;

  /// The amount charged, if one was found.
  final Money? amount;
}

/// A subscription found in the mail.
final class Subscription {
  const Subscription({
    required this.company,
    required this.name,
    required this.records,
    required this.cadence,
    required this.amount,
    required this.status,
    required this.nextCharge,
    this.variable = false,
    this.spentLastYear,
    this.period,
    this.endsOn,
    this.billers = const {},
  });

  /// The company's domain, or for a company billed through a payment
  /// service, `Acme via stripe.com` ([SubscriptionFinder.billerOf]).
  final String company;

  /// The senders it was found in ([SubscriptionEmail.biller]) when more
  /// than [company]: a sister domain of the same brand that sends its
  /// bills or takes its payments (`examplepower.com` and
  /// `examplepowerpay.com`). Empty for [company] alone.
  final Set<String> billers;

  /// For a cancelled one: the last day it lasts, when the mail says
  /// ("your benefits stop on 9 May").
  final DateTime? endsOn;

  /// What to call it: the sender's name most used, else the domain.
  final String name;

  /// Its emails, newest first.
  final List<SubscriptionRecord> records;

  /// Null when it can't be told (one receipt, no wording about it), or
  /// when [period] is none of these (every 2 months).
  final Cadence? cadence;

  /// The exact time between charges ("every 30 days"), when known.
  final BillingPeriod? period;

  BillingPeriod? get _period {
    final c = cadence;
    return period ?? (c == null ? null : BillingPeriod.of(c));
  }

  /// The latest amount charged, if any was found.
  final Money? amount;
  final SubscriptionStatus status;

  /// Estimated from the last charge and the cadence, for active ones.
  final DateTime? nextCharge;

  /// The amount changes from charge to charge (a utility or phone bill):
  /// [amount] is then the average of the recent charges, and a change is
  /// not a price change.
  final bool variable;

  /// For a [variable] one with a year of receipts: what it charged in
  /// the last 12 months (several domains or a utility bill add up
  /// differently than one price times the cadence).
  final Money? spentLastYear;

  DateTime? get lastCharge => records
      .where((r) => r.event == SubscriptionEvent.charge)
      .map((r) => r.email.at)
      .firstOrNull;

  /// The amount per month (for a total), or null.
  Money? get monthly {
    if (spentLastYear case final y?) {
      return Money((y.minor / 12).round(), y.currency);
    }
    final a = amount;
    final p = _period;
    if (a == null || p == null) return null;
    return Money((a.minor * p.perMonth).round(), a.currency);
  }

  /// The amount per year, or null.
  Money? get yearly {
    if (spentLastYear case final y?) return y;
    final a = amount;
    final p = _period;
    if (a == null || p == null) return null;
    return Money((a.minor * p.perMonth * 12).round(), a.currency);
  }
}

/// Finds paid subscriptions in receipts and renewal mail, on the device.
///
/// A company counts when its mail speaks of a subscription (subscription,
/// membership, renews, plan, trial...), or when it charged at a regular
/// interval at least three times; one-off shop orders do not.
abstract final class SubscriptionFinder {
  /// Subject words of mail worth looking at (also used to pick it from
  /// the store).
  static const subjectWords = [
    'receipt',
    'invoice',
    'subscription',
    'subscribed',
    'renew',
    'membership',
    'payment',
    'billing',
    'charged',
    'your plan',
    'trial',
    'cancel',
    'auto-renew',
    'bill',
  ];

  /// Words of a preview that make mail worth looking at although its
  /// subject names none of [subjectWords] ("Welcome aboard!": "you're now a
  /// paid member", "Total today: $4.50").
  static const previewWords = [
    'now a paid',
    'trial has ended',
    'charged monthly',
    'billed monthly',
    'charged yearly',
    'billed yearly',
    'billed annually',
    'total today',
  ];

  static final _subscriptionWords = RegExp(
    r'\b(?:subscriptions?|subscribed|membership|renews?|renewed|renewal|'
    r'auto-renew\w*|recurring|your plan|premium plan|billing period|'
    r'next billing|next payment|free trial|trial|'
    r'unused time on|remaining time on|'
    // Phone, broadband and utility bills recur too.
    r'e-?bill|monthly (?:bill|invoice)|latest bill|'
    r'(?:mobile|phone|broadband|internet|fibre|fiber|utility|utilities|'
    r'electricity|water|gas|postpaid|cable|tv)\s+bills?|'
    r'bill for (?:the month of )?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|'
    r'oct|nov|dec)[a-z]*)\b',
    caseSensitive: false,
  );

  static final _cancelWords = RegExp(
    r'\b(?:cancel(?:l)?ed|cancel(?:l)?ation|has ended|have ended|will end|'
    r'won.t renew|will not renew|expired|unsubscribed from your plan)\b',
    caseSensitive: false,
  );

  static final _trialWords = RegExp(
    r'\b(?:free trial|trial (?:starts|started|ends|ending|is ending|will end))\b',
    caseSensitive: false,
  );

  static final _chargeWords = RegExp(
    r'\b(?:receipt|invoice|payment (?:received|confirmation|successful)|'
    r'paid|charged|renewed|order confirmation|your order|billing statement|'
    r'successful payment|payment (?:was )?successful|bill payment|'
    r"e-?bill|your (?:[\w.&'-]+ ){0,3}bill|bill (?:is|for))\b",
    caseSensitive: false,
  );

  static final _cadenceWords = <Cadence, RegExp>{
    Cadence.weekly: RegExp(
      r'\b(?:weekly|per week|/\s?wk|a week)\b',
      caseSensitive: false,
    ),
    Cadence.monthly: RegExp(
      r'\b(?:monthly|per month|/\s?mo(?:nth)?|a month|every month)\b',
      caseSensitive: false,
    ),
    Cadence.quarterly: RegExp(
      r'\b(?:quarterly|every 3 months)\b',
      caseSensitive: false,
    ),
    Cadence.yearly: RegExp(
      r'\b(?:yearly|annual(?:ly)?|per year|/\s?y(?:ea)?r|a year|every year|'
      r'12 months|1 year|one year)\b',
      caseSensitive: false,
    ),
  };

  static final _replyOrForward = RegExp(
    r'^\s*(?:\[[^\]]*\]\s*)?(?:re|fwd?|aw|wg|sv|vs|tr|rv)\s*(?:\[\d+\])?\s*:',
    caseSensitive: false,
  );

  /// "Re: ..." or "Fwd: ...": a discussion, not a company's own mail.
  static bool isReplyOrForward(String subject) =>
      _replyOrForward.hasMatch(subject);

  /// A cancelled shop or food order, not a subscription.
  static final _orderWords = RegExp(
    r'\b(?:order|delivery|booking|ride|trip)\b',
    caseSensitive: false,
  );

  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static const _month =
      r'(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?';

  /// A billing period as receipts print it ("Sep 28, 2026 – Sep 28, 2027",
  /// "28 Sep 2026 - 28 Sep 2027", "2026-09-28 to 2027-09-28"), and with
  /// the year printed once, at the end ("Mar 3 – Apr 3, 2026", "1 Oct - 31
  /// Oct 2026"). Each is read as (year, month, day) of its start and end;
  /// a start year of null is the end's (or the year before, for "Dec 3 –
  /// Jan 3, 2027").
  static final _periods = <(RegExp, (int?, int, int), (int, int, int))>[
    (
      RegExp(
        '$_month\\s+(\\d{1,2}),?\\s+(\\d{4})\\s*(?:[-–—]|to|until)\\s*'
        '$_month\\s+(\\d{1,2}),?\\s+(\\d{4})',
        caseSensitive: false,
      ),
      (3, 1, 2),
      (6, 4, 5),
    ),
    (
      RegExp(
        '(\\d{1,2})\\s+$_month,?\\s+(\\d{4})\\s*(?:[-–—]|to|until)\\s*'
        '(\\d{1,2})\\s+$_month,?\\s+(\\d{4})',
        caseSensitive: false,
      ),
      (3, 2, 1),
      (6, 5, 4),
    ),
    (
      RegExp(
        r'(\d{4})-(\d{2})-(\d{2})\s*(?:[-–—]|to|until)\s*'
        r'(\d{4})-(\d{2})-(\d{2})',
      ),
      (1, 2, 3),
      (4, 5, 6),
    ),
    (
      RegExp(
        '$_month\\s+(\\d{1,2})\\s*(?:[-–—]|to|until)\\s*'
        '$_month\\s+(\\d{1,2}),?\\s+(\\d{4})',
        caseSensitive: false,
      ),
      (null, 1, 2),
      (5, 3, 4),
    ),
    (
      RegExp(
        '(?<!\\d)(\\d{1,2})\\s+$_month\\s*(?:[-–—]|to|until)\\s*'
        '(\\d{1,2})\\s+$_month,?\\s+(\\d{4})',
        caseSensitive: false,
      ),
      (null, 2, 1),
      (5, 4, 3),
    ),
  ];

  /// The length of a billing period printed in [text], if any.
  static Duration? billingPeriodIn(String text) {
    if (_rangeIn(text) case (:final from, :final to)) {
      return to.difference(from);
    }
    return null;
  }

  /// The first billing period printed in [text], as its first and last
  /// day.
  static ({DateTime from, DateTime to})? _rangeIn(String text) {
    for (final (re, start, end) in _periods) {
      for (final m in re.allMatches(text)) {
        DateTime? date((int?, int, int) groups, [int? inYear]) {
          final (y, mo, d) = groups;
          final year = y == null ? inYear : int.tryParse(m[y]!);
          final month = int.tryParse(m[mo]!) ?? _months[m[mo]!.toLowerCase()];
          final day = int.tryParse(m[d]!);
          if (year == null || month == null || day == null) return null;
          if (month < 1 || month > 12 || day < 1 || day > 31) return null;
          return DateTime.utc(year, month, day);
        }

        final to = date(end);
        var from = date(start, to?.year);
        // "Dec 3 – Jan 3, 2027": the start is in the year before.
        if (from != null &&
            to != null &&
            start.$1 == null &&
            from.isAfter(to)) {
          from = DateTime.utc(from.year - 1, from.month, from.day);
        }
        if (from == null || to == null || !to.isAfter(from)) continue;
        final length = to.difference(from).inDays;
        if (length >= 6 && length <= 400) return (from: from, to: to);
      }
    }
    return null;
  }

  /// The billing period printed in [text] as dates ("Dec 18, 2025 – Jan
  /// 18, 2026" is monthly, and so is "1 Mar – 31 Mar", an inclusive end;
  /// other lengths are days), or null.
  static BillingPeriod? _periodOfRange(String text) {
    final r = _rangeIn(text);
    if (r == null) return null;
    final months = (r.to.year - r.from.year) * 12 + r.to.month - r.from.month;
    for (final m in [months, months + 1]) {
      if (m < 1) continue;
      final end = BillingPeriod.months(m).after(r.from);
      final gap = end.difference(r.to).inDays;
      // The same day of the month, or the day before (an inclusive end).
      if (gap == 0 || gap == 1) return BillingPeriod.months(m);
    }
    // "3 Mar - 1 Apr": 30 days, the last one included.
    var days = r.to.difference(r.from).inDays;
    if (!_usualDays.contains(days) && _usualDays.contains(days + 1)) days++;
    return _ofDays(days);
  }

  /// Plans' usual lengths in days.
  static const _usualDays = {7, 14, 28, 30, 31, 90, 91, 182, 183, 365, 366};

  /// [n] days as a period: whole weeks as weeks.
  static BillingPeriod? _ofDays(int n) {
    if (n < 6 || n > 400) return null;
    if (n % 7 == 0 && n <= 56) return BillingPeriod(n ~/ 7, PeriodUnit.week);
    return BillingPeriod.days(n);
  }

  static const _numberWords = {
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'six': 6,
    'twelve': 12,
  };

  static const _count = r'(\d{1,3}|one|two|three|four|six|twelve)';

  /// "every 30 days", "every 6 months", "each 2 weeks".
  static final _everyN = RegExp(
    '\\b(?:every|each)\\s+$_count\\s+(day|week|month|year)s?\\b',
    caseSensitive: false,
  );

  /// "30-day plan", "6-month membership", "12 month subscription".
  static final _nUnitPlan = RegExp(
    '\\b$_count[-\\s](day|week|month|year)s?\\s+(?:plan|subscription|'
    r'membership|pass|package|term|contract|bundle|cycle|renewal|'
    r'billing(?:\s+(?:cycle|period))?)\b',
    caseSensitive: false,
  );

  /// "billed monthly", "renews every year", "charged quarterly".
  static final _billedEvery = RegExp(
    r'\b(?:billed|charged|paid|payable|renews?|renewed|renewing|recurring|'
    r'auto-?renews?)\s+((?:every|each)\s+(?:week|month|quarter|year)|'
    r'weekly|fortnightly|bi-?weekly|monthly|quarterly|semi-?annually|'
    r'half-?yearly|bi-?annually|annually|yearly)\b',
    caseSensitive: false,
  );

  /// "annual plan", "monthly subscription", "semi-annual membership".
  static final _adjectivePlan = RegExp(
    r'\b(weekly|fortnightly|bi-?weekly|monthly|quarterly|semi-?annual|'
    r'half-?yearly|bi-?annual|annual|yearly)\s+(?:plan|subscription|'
    r'membership|billing|fee|pass|renewal|charge|payment)\b',
    caseSensitive: false,
  );

  static BillingPeriod? _ofWord(String word) {
    final w = word.toLowerCase().replaceAll(RegExp(r'[\s-]+'), ' ');
    if (w.endsWith('week') || w == 'weekly') return BillingPeriod.weekly;
    if (w == 'fortnightly' || w.startsWith('bi') && w.endsWith('weekly')) {
      return const BillingPeriod(2, PeriodUnit.week);
    }
    if (w.endsWith('month') || w == 'monthly') return BillingPeriod.monthly;
    if (w.endsWith('quarter') || w == 'quarterly') {
      return BillingPeriod.quarterly;
    }
    if (w.startsWith('semi') || w.startsWith('half') || w.startsWith('bi')) {
      return BillingPeriod.halfYearly;
    }
    return BillingPeriod.yearly;
  }

  static BillingPeriod? _ofCount(String count, String unit) {
    final n = int.tryParse(count) ?? _numberWords[count.toLowerCase()] ?? 0;
    return switch (unit.toLowerCase()) {
      'day' => _ofDays(n),
      'week' when n >= 1 && n <= 8 => BillingPeriod(n, PeriodUnit.week),
      'month' when n >= 1 && n <= 24 => BillingPeriod.months(n),
      'year' when n >= 1 && n <= 3 => BillingPeriod.months(12 * n),
      _ => null,
    };
  }

  /// Words near a stated period that make it something else than how
  /// often a plan charges: "save 30% for 6 months", "30-day free
  /// returns", "valid for 30 days", "switch to an annual plan".
  static final _notAPeriod = RegExp(
    r'\b(?:save|saving|savings|off|discount\w*|promo\w*|deals?|offers?|'
    r'coupons?|vouchers?|valid|validity|expir\w*|returns?|refund\w*|'
    r'warranty|guarantee\w*|trial|free|upgrade|switch|compare|instead|'
    r'cashback|or)\b|%',
    caseSensitive: false,
  );

  /// Whether the words around [start]..[end] in [text] (the same
  /// sentence) read as a promotion or a voucher.
  static bool _promotional(String text, int start, int end) {
    var before = text.substring(start - 40 < 0 ? 0 : start - 40, start);
    var after = text.substring(
      end,
      end + 25 > text.length ? text.length : end + 25,
    );
    before = before.split(RegExp(r'[\n.!?]')).last;
    after = after.split(RegExp(r'[\n.!?]')).first;
    return _notAPeriod.hasMatch(before) || _notAPeriod.hasMatch(after);
  }

  /// The billing period [text] states: printed as dates, else in words
  /// ("every 30 days", "6-month plan", "billed quarterly", "annual
  /// plan"), not in a promotion or a voucher. Null when it states none.
  static BillingPeriod? statedPeriodIn(String text) {
    if (text.isEmpty) return null;
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    final range = _periodOfRange(sample);
    final found = <(int, BillingPeriod)>[];
    for (final re in [_everyN, _nUnitPlan]) {
      for (final m in re.allMatches(sample)) {
        final p = _ofCount(m[1]!, m[2]!);
        if (p != null && !_promotional(sample, m.start, m.end)) {
          found.add((m.start, p));
        }
      }
    }
    for (final re in [_billedEvery, _adjectivePlan]) {
      for (final m in re.allMatches(sample)) {
        final p = _ofWord(m[1]!);
        if (p != null && !_promotional(sample, m.start, m.end)) {
          found.add((m.start, p));
        }
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    final words = found.firstOrNull?.$2;
    // The dates, unless the words say the same more exactly ("30-day
    // pass", 10 Jan - 9 Feb).
    if (range != null &&
        (words == null || (words.days - range.days).abs() > 2)) {
      return range;
    }
    return words;
  }

  /// Looser wording ("per month", "a year", "/mo") for when nothing
  /// states the period: the cadence it names, not in a promotion.
  static BillingPeriod? _loosePeriodIn(String text) {
    // Domains are registered by the year.
    if (_domainRenewal.hasMatch(text)) return BillingPeriod.yearly;
    for (final MapEntry(key: cadence, value: words) in _cadenceWords.entries) {
      for (final m in words.allMatches(text)) {
        if (!_promotional(text, m.start, m.end)) {
          return BillingPeriod.of(cadence);
        }
      }
    }
    return null;
  }

  static final _domainRenewal = RegExp(
    r'\bdomain (?:renewal|registration)\b',
    caseSensitive: false,
  );

  /// Words right before the date of the next charge.
  static final _renewsOnWords = RegExp(
    r'\b(?:(?:will\s+)?(?:auto-?)?renews?|renewing|will\s+be\s+(?:renewed|'
    r'charged|billed)|next\s+(?:renewal|billing|payment|charge)(?:\s+date)?|'
    r'(?:renewal|billing)\s+date|'
    // "will be charged monthly starting on Apr 6", "Billing starts: Apr 6".
    r'(?:charged|billed)(?:\s+\w+)?\s+starting(?:\s+(?:on|from))?|'
    r'billing\s+starts(?:\s+on)?)\b',
    caseSensitive: false,
  );

  /// The date of the next charge [text] states ("renews on 12 Dec 2026",
  /// "Your next renewal date is 12-04-2027"), read against [sent]; only
  /// one after [sent].
  static DateTime? renewalDateIn(String text, DateTime sent) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    final sentDay = DateTime.utc(sent.year, sent.month, sent.day);
    final labels = [
      ..._renewsOnWords.allMatches(sample),
      // "Your plan ends 2027/03/14; it renews then": a paid
      // plan that renews when it ends (not one cancelled).
      if (_renewalSubject.hasMatch(sample) &&
          !_cancelWords.allMatches(sample).any((m) => !_endOfTrial(sample, m)))
        ..._endsThenRenews.allMatches(sample),
    ]..sort((a, b) => a.start.compareTo(b.start));
    for (final m in labels) {
      final rest = sample.substring(
        m.end,
        m.end + 40 > sample.length ? sample.length : m.end + 40,
      );
      DateTime? on;
      if (DueDates.datesIn(rest, reference: sent).firstOrNull case final d?
          when d.start <= 12) {
        on = d.date;
      } else if (_yearFirst.firstMatch(rest) case final y?) {
        final (year, month, day) = (
          int.parse(y[1]!),
          int.parse(y[2]!),
          int.parse(y[3]!),
        );
        final d = DateTime.utc(year, month, day);
        if (d.month == month && d.day == day) on = d;
      }
      if (on == null) continue;
      final days = on.difference(sentDay).inDays;
      if (days >= 1 && days <= 400) return on;
    }
    return null;
  }

  /// "Your plan ends", "membership expires on".
  static final _endsThenRenews = RegExp(
    r'\b(?:plan|membership|subscription)\s+(?:ends|expires)(?:\s+on)?\b',
    caseSensitive: false,
  );

  /// "2027/03/14" right after the words.
  static final _yearFirst = RegExp(r'^\W{0,6}(\d{4})/(\d{1,2})/(\d{1,2})\b');

  /// Whether [email] itself is about a subscription: its wording, or a
  /// billing period.
  static bool speaksOfSubscription(SubscriptionEmail email) =>
      _speaksOfSubscription(email);

  static bool _speaksOfSubscription(SubscriptionEmail email) =>
      _subscriptionWords.hasMatch(email.subject) ||
      billingPeriodIn(email.text) != null ||
      // A shop order's page names "Membership" or a trial in its links and
      // footer; that is not about this order.
      (_subscriptionWords.hasMatch(email.text) && !isShopOrder(email));

  /// What a one-off shop order says of itself: its order number or
  /// status, its parcel, the shop's purchase history.
  static final _shopOrder = RegExp(
    r'\b(?:order (?:no\.?|number|#|status|id|details|summary)|in transit|'
    r'(?:has|have) (?:been )?shipped|out for delivery|track (?:your )?'
    r'(?:order|parcel|package)|purchase history|click (?:&|and) collect)',
    caseSensitive: false,
  );

  /// Whether [email] reads as a one-off shop order (an order number, a
  /// parcel on its way) and its subject names no subscription.
  static bool isShopOrder(SubscriptionEmail email) =>
      !_subscriptionWords.hasMatch(email.subject) &&
      (_shopOrder.hasMatch(email.subject) || _shopOrder.hasMatch(email.text));

  /// An account statement (bank, card, brokerage, CDP): what the account
  /// holds or did, not a charge.
  static final _accountStatement = RegExp(
    r'\b(?:account statement|statement of account|e-?statements?|'
    r'(?:bank|card|portfolio|securities|monthly|annual) statement)\b',
    caseSensitive: false,
  );

  /// An account statement (bank, card, brokerage, CDP), not a bill: its
  /// [subject] says statement and not bill or invoice.
  static bool isAccountStatement(String subject) =>
      _accountStatement.hasMatch(subject) &&
      !RegExp(r'\b(?:bill|invoice)', caseSensitive: false).hasMatch(subject);

  /// A reminder before a renewal or an expiry.
  static final _reminderWords = RegExp(
    r'\b(?:renewal (?:notice|reminder)|reminder|upcoming|expir(?:es|ing|ation)|'
    r'approaching|will (?:auto-?)?renew|due soon|is due)\b',
    caseSensitive: false,
  );

  /// A payment that didn't go through: nothing was charged.
  static final _failedWords = RegExp(
    r'\b(?:unsuccessful|failed|declined|unable to (?:process|charge)|'
    r'could not be (?:processed|charged)|payment (?:issue|problem)|'
    r'didn.t go through|did not go through|was not (?:processed|successful))\b',
    caseSensitive: false,
  );

  /// What [email] says.
  static SubscriptionEvent eventOf(SubscriptionEmail email) {
    final subject = email.subject;
    if (_failedWords.hasMatch(subject)) return SubscriptionEvent.notice;
    // "Renewal notice: expiring in 60 days" is a reminder, whatever the
    // body says about what happens if it isn't renewed.
    if (_reminderWords.hasMatch(subject) &&
        !_cancelWords.hasMatch(subject) &&
        !_chargeWords.hasMatch(subject)) {
      return SubscriptionEvent.notice;
    }
    if (isAccountStatement(subject)) return SubscriptionEvent.notice;
    if (_cancelWords.hasMatch(subject)) {
      // "Your order was cancelled" is about an order.
      return _orderWords.hasMatch(subject) &&
              !_subscriptionWords.hasMatch(subject)
          ? SubscriptionEvent.notice
          : SubscriptionEvent.cancelled;
    }
    if (_trialWords.hasMatch(subject)) return SubscriptionEvent.trial;
    if (_promoSubject.hasMatch(subject) && !_ownChargeWords.hasMatch(subject)) {
      return SubscriptionEvent.notice;
    }
    if (_chargeWords.hasMatch(subject)) return SubscriptionEvent.charge;
    final text = email.text;
    // "Data plan renewal": "Your plan is renewed. Your next renewal date
    // is 12-04-2027."; "Your free trial has ended, and you're now a paid
    // member".
    if ((_renewalSubject.hasMatch(subject) && _renewedText.hasMatch(text)) ||
        _paidNow.hasMatch(text)) {
      return SubscriptionEvent.charge;
    }
    // "Welcome to your membership ... Total today: $4.50", "We've
    // successfully deducted $7.00 for this bill".
    if (_moneyTaken.hasMatch(text) && !_failedWords.hasMatch(text)) {
      return SubscriptionEvent.charge;
    }
    if (_cancelWords.allMatches(text).any((m) => !_endOfTrial(text, m))) {
      return SubscriptionEvent.cancelled;
    }
    return SubscriptionEvent.notice;
  }

  static final _renewalSubject = RegExp(
    r'\brenew(?:al|ed|s)?\b',
    caseSensitive: false,
  );

  /// A renewal done: "is renewed", "has been successfully renewed" (not
  /// "will be renewed").
  static final _renewedText = RegExp(
    r'\b(?:is|was|were|has been|have been)\s+'
    r'(?:successfully\s+|automatically\s+|auto-?)?renewed\b',
    caseSensitive: false,
  );

  /// A trial turned into a paid plan.
  static final _paidNow = RegExp(
    r"\byou(?:'|’|\s+a)re now a paid\b|\byou(?:'|’|\s+ha)ve been upgraded to (?:a )?paid\b",
    caseSensitive: false,
  );

  /// The body says money was taken, though the subject does not.
  static final _moneyTaken = RegExp(
    r"\b(?:total today|amount paid|you(?:'ve| have)? been charged|"
    r"we(?:'ve| have) (?:successfully )?(?:charged|deducted|debited)|"
    r'(?:has|have) been (?:successfully )?(?:deducted|debited|paid)|'
    r'successfully (?:deducted|debited|paid|charged))\b',
    caseSensitive: false,
  );

  /// A promotion's subject: "Pay your electricity bill with us and earn 5%
  /// cashback", "$30 bill rebate".
  static final _promoSubject = RegExp(
    r'\b(?:earn|cash ?back|rewards?|promo\w*|offers?|deals?|win|discount|'
    r'vouchers?|rebates?|save|sale)\b|%',
    caseSensitive: false,
  );

  /// What a bill or receipt says of itself, promotion or not.
  static final _ownChargeWords = RegExp(
    r'\b(?:receipt|invoice|paid|charged|renewed|e-?bill|bill (?:is|for)|'
    r'payment (?:received|confirmation|successful))\b',
    caseSensitive: false,
  );

  /// "Your free trial has ended": the trial, not the subscription, ended.
  static bool _endOfTrial(String text, RegExpMatch m) => RegExp(
    r'\btrial\s+(?:period\s+)?$',
    caseSensitive: false,
  ).hasMatch(text.substring(m.start - 20 < 0 ? 0 : m.start - 20, m.start));

  // ------------------------------------------------------------ amounts

  /// Currency marks, longest first, and the code each stands for (a lone
  /// `$` stays `$`: it may be any dollar).
  static const _marks = {
    'US\$': 'USD',
    'S\$': 'SGD',
    'A\$': 'AUD',
    'C\$': 'CAD',
    'HK\$': 'HKD',
    'NZ\$': 'NZD',
    'RM': 'MYR',
    '€': 'EUR',
    '£': 'GBP',
    '¥': 'JPY',
    '₹': 'INR',
    '₩': 'KRW',
    '\$': '\$',
  };

  static const _codes = {
    'USD',
    'SGD',
    'AUD',
    'CAD',
    'HKD',
    'NZD',
    'MYR',
    'EUR',
    'GBP',
    'JPY',
    'INR',
    'KRW',
    'CNY',
    'CHF',
    'SEK',
    'NOK',
    'DKK',
    'IDR',
    'THB',
    'PHP',
    'VND',
    'TWD',
  };

  static final _number =
      r'(\d{1,3}(?:[,.\s]\d{3})*(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)';

  static final _amount = RegExp(
    '(?:(${_marks.keys.map(RegExp.escape).join('|')}|${_codes.join('|')})\\s?$_number'
    '|$_number\\s?(${_codes.join('|')}(?![A-Za-z])|€|£))',
  );

  /// Words right before the amount actually paid (or to pay, on a bill).
  static final _paidWords = RegExp(
    r'\b(?:amount (?:paid|charged)|you paid|total paid|total charged|'
    r'grand total|total (?:amount )?due|amount due|amount payable|'
    r'outstanding (?:amount|balance)\b[^\n]{0,40}?)\W*$',
    caseSensitive: false,
  );

  static final _totalWords = RegExp(
    r'\b(?:total|amount (?:paid|charged|due)?|charged|you paid|paid|price|grand total|billed)\b',
    caseSensitive: false,
  );

  /// A total that is not what was paid: "Total excluding tax".
  static final _partTotal = RegExp(
    r'\b(?:sub-?total|total (?:excl(?:uding|\.)?|ex\.?|before|without|net)\b)',
    caseSensitive: false,
  );

  /// The amount [text] says was charged: one right after "Amount paid" or
  /// "Grand total"; else the first after a word such as "Total" or
  /// "charged" (not "Total excluding tax"); else the first one at all.
  static Money? amountIn(String text) {
    if (text.isEmpty) return null;
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    Money? first;
    Money? total;
    for (final m in _amount.allMatches(sample)) {
      final money = _money(m);
      if (money == null) continue;
      final before = sample.substring(
        m.start - 40 < 0 ? 0 : m.start - 40,
        m.start,
      );
      if (_isCredit(sample, m.start, m.end)) {
        // "Total due: -$21.40": nothing to pay. Other credits ("Unused
        // time -$14.32") are not the price.
        if (_creditTotal.hasMatch(before)) return null;
        continue;
      }
      first ??= money;
      if (_paidWords.hasMatch(before)) return money;
      // The words closest to the amount: the last line before it.
      final line = before
          .split('\n')
          .lastWhere((l) => l.trim().isNotEmpty, orElse: () => before);
      final near = line.trim().isEmpty || _amount.hasMatch(line)
          ? before
          : line;
      if (total == null &&
          _totalWords.hasMatch(near) &&
          !_partTotal.hasMatch(near)) {
        total = money;
      }
    }
    return total ?? first;
  }

  /// Every amount in [text], with where it is; not credits ("-$5.00",
  /// "$5.00 CR").
  static Iterable<({Money money, int start, int end})> amountsIn(
    String text,
  ) sync* {
    for (final m in _amount.allMatches(text)) {
      if (_isCredit(text, m.start, m.end)) continue;
      if (_money(m) case final money?) {
        yield (money: money, start: m.start, end: m.end);
      }
    }
  }

  /// Whether the amount at [start]..[end] of [text] is a credit: a minus
  /// sign right before it ("is -$21.40", not "Price – $5" or "$10-$20"),
  /// or "CR" after it.
  static bool _isCredit(String text, int start, int end) {
    final before = text.substring(start - 2 < 0 ? 0 : start - 2, start);
    if (RegExp(r'(?:^|[\s(:])[-−–]$').hasMatch(before)) return true;
    final after = text.substring(
      end,
      end + 8 > text.length ? text.length : end + 8,
    );
    return RegExp(r'^\s?(?:CR|Cr)\b').hasMatch(after);
  }

  /// Whether [text] says the total due is a credit ("The total due for
  /// this bill is -$21.40"): nothing to pay.
  static bool owesNothing(String text) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    for (final m in _amount.allMatches(sample)) {
      if (!_isCredit(sample, m.start, m.end)) continue;
      final before = sample.substring(
        m.start - 40 < 0 ? 0 : m.start - 40,
        m.start,
      );
      if (_creditTotal.hasMatch(before)) return true;
    }
    return false;
  }

  /// Words right before a credit that make it the total: "The total due
  /// for this bill is -$21.40", "Balance: -$3.00" (not "Total discount").
  static final _creditTotal = RegExp(
    r'\b(?:total|balance|amount due|amount payable)\b'
    r'(?![^\n]*\b(?:discount|savings?|saved|off|refund\w*|rebate)\b)'
    r'[^\n\d$€£]{0,30}$',
    caseSensitive: false,
  );

  static Money? _money(RegExpMatch m) {
    final mark = m.group(1) ?? m.group(4);
    final digits = m.group(2) ?? m.group(3);
    if (mark == null || digits == null) return null;
    final currency = _marks[mark] ?? mark;
    final minor = _minorUnits(digits.replaceAll(' ', ''));
    if (minor == null || minor <= 0 || minor > 100000000) return null;
    return Money(minor, currency);
  }

  /// "1,234.56" or "1.234,56" or "12" -> cents.
  static int? _minorUnits(String digits) {
    final decimals = RegExp(r'[.,](\d{1,2})$').firstMatch(digits);
    final whole =
        (decimals == null ? digits : digits.substring(0, decimals.start))
            .replaceAll(RegExp('[.,]'), '');
    final units = int.tryParse(whole);
    if (units == null) return null;
    final cents = decimals == null
        ? 0
        : int.parse(decimals.group(1)!.padRight(2, '0'));
    return units * 100 + cents;
  }

  // ------------------------------------------------------------- finding

  /// The subscriptions in [emails] (any order), most recently charged
  /// first; cancelled and lapsed ones after the active ones. [now] is
  /// today.
  static List<Subscription> find(
    Iterable<SubscriptionEmail> emails, {
    required DateTime now,
  }) {
    final byCompany = <String, List<SubscriptionEmail>>{};
    for (final e in emails) {
      // Replies and forwards (a discussion that mentions a receipt or a
      // subscription) are not the company's own mail.
      if (isReplyOrForward(e.subject)) continue;
      byCompany.putIfAbsent(e.biller, () => []).add(e);
    }
    final found = <Subscription>[];
    for (final (:company, :billers, :list) in _withSisters(byCompany)) {
      list.sort((a, b) => b.at.compareTo(a.at));
      final records = [
        for (final e in list)
          if (eventOf(e) case final event)
            SubscriptionRecord(
              e,
              event,
              // What a notice or a promotion names is not a price paid.
              event == SubscriptionEvent.charge
                  ? amountIn('${e.subject}\n${e.text}')
                  : null,
            ),
      ];
      var charges = records
          .where((r) => r.event == SubscriptionEvent.charge)
          .toList();
      // Charged at a steady interval at least three times: a subscription
      // even without the word, unless the receipts are shop orders or
      // purchases of varying amounts that happen to fall a month apart.
      final regular =
          charges.length >= 3 &&
          _periodFromDates([for (final r in charges) r.email.at]) != null &&
          _steady(charges);
      if (!regular) {
        // A company that also sells one-off things (rides, food, shop
        // orders) sends receipts that are not the subscription's: only
        // those that speak of it count, unless there are just one or two.
        final own = [
          for (final r in charges)
            if (_speaksOfSubscription(r.email)) r,
        ];
        if (own.isNotEmpty || charges.length > 2) {
          final dropped = {
            for (final r in charges) r,
            // Their other mail ("your order was cancelled") too.
            for (final r in records)
              if (r.event == SubscriptionEvent.notice &&
                  !_speaksOfSubscription(r.email))
                r,
          }..removeAll(own);
          records.removeWhere(dropped.contains);
          charges = own;
        }
      }
      charges = _oneChargePerBill(charges, records);
      final says = records.any((r) => _speaksOfSubscription(r.email));
      if (!says && !regular) continue;
      final name = _nameOf(company, list);
      if (charges.isEmpty) {
        // Nothing paid yet (only a free trial, or talk of plans): not a
        // subscription until a charge comes; unless the company says a
        // paid plan was cancelled or has ended (its receipts may come from
        // an app store or another domain).
        final ended = records
            .where(
              (r) =>
                  r.event == SubscriptionEvent.cancelled &&
                  _endsPaidPlan(r.email),
            )
            .firstOrNull;
        if (ended == null ||
            records.any((r) => r.event == SubscriptionEvent.trial)) {
          continue;
        }
        final period = records
            .map((r) => statedPeriodIn(r.email.text))
            .nonNulls
            .firstOrNull;
        found.add(
          Subscription(
            company: company,
            name: name,
            records: List.unmodifiable(records),
            cadence: period?.cadence,
            period: period,
            amount: null,
            status: SubscriptionStatus.cancelled,
            nextCharge: null,
            endsOn: endDateIn(ended.email.text, ended.email.at),
            billers: billers.length > 1 ? billers : const {},
          ),
        );
        continue;
      }

      final lastCharge = charges.first.email.at;
      // The next charge as the newest mail since the last charge states
      // it ("renews on 12 Dec 2026", "next renewal date is 12-04-2027"),
      // or one sent with it about the same bill (the renewal notice an hour
      // before the receipt), when it is later than this bill.
      DateTime? renewsOn;
      for (final r in records) {
        final twin = r.email.at.isBefore(lastCharge);
        if (r.email.at.isBefore(lastCharge.subtract(sameBill))) break;
        if (r.event == SubscriptionEvent.cancelled) {
          if (twin) continue;
          break;
        }
        if (renewalDateIn(r.email.text, r.email.at) case final d?
            when !twin || d.isAfter(lastCharge.add(sameBill))) {
          renewsOn = d;
          break;
        }
      }
      // How often: as printed or stated (receipts first), else from the
      // dates of the charges, else looser wording, else the gap to the
      // stated next charge.
      final byKind = [
        ...charges,
        for (final r in records)
          if (r.event != SubscriptionEvent.charge) r,
      ];
      final stated = byKind
          .map((r) => statedPeriodIn(r.email.text))
          .nonNulls
          .firstOrNull;
      final dated = _periodFromDates([for (final r in charges) r.email.at]);
      final period =
          // A bill period that reads as a month ("12 Jun - 11 Jul") on
          // charges a fixed number of days apart: that many days.
          (stated == BillingPeriod.monthly && dated?.unit == PeriodUnit.day
              ? dated
              : stated) ??
          dated ??
          byKind
              .map((r) => _loosePeriodIn('${r.email.subject}\n${r.email.text}'))
              .nonNulls
              .firstOrNull ??
          (renewsOn == null ? null : _periodUntil(lastCharge, renewsOn));
      final cadence = period?.cadence;

      // The newest amounts, in the latest currency.
      final recent = [
        for (final a in charges.map((r) => r.amount).nonNulls.take(6))
          if (a.currency ==
              charges.map((r) => r.amount).nonNulls.first.currency)
            a,
      ];
      final variable = {for (final a in recent) a.minor}.length >= 3;
      var amount = variable ? _average(recent) : recent.firstOrNull;
      // A price change announced since the last charge: what it charges
      // from now on ("from $9.49/month to $10.99/month").
      if (!variable && amount != null) {
        final was = amount;
        for (final r in records) {
          if (!r.email.at.isAfter(lastCharge)) break;
          if (_newPrice('${r.email.subject}\n${r.email.text}', was)
              case final p?) {
            amount = p;
            break;
          }
        }
      }
      final cancellation = records
          .where((r) => r.event == SubscriptionEvent.cancelled)
          .firstOrNull;
      final cancelledAt = cancellation?.email.at;
      final length = (period ?? BillingPeriod.monthly).length;
      final today = DateTime.utc(now.year, now.month, now.day);
      bool due(DateTime d) =>
          !DateTime.utc(d.year, d.month, d.day).isBefore(today);
      final SubscriptionStatus status;
      if (cancelledAt != null && cancelledAt.isAfter(lastCharge)) {
        status = SubscriptionStatus.cancelled;
      } else if (now.difference(renewsOn ?? lastCharge) >
          length * (renewsOn == null ? 1.5 : 0.5) + const Duration(days: 7)) {
        status = SubscriptionStatus.lapsed;
      } else {
        status = SubscriptionStatus.active;
      }
      DateTime? next;
      if (status == SubscriptionStatus.active && renewsOn != null) {
        // A stated date gone by: the periods after it.
        var n = 0;
        DateTime at(int n) => n == 0 ? renewsOn! : period!.after(renewsOn!, n);
        while (!due(at(n)) && period != null && n < 1000) {
          n++;
        }
        next = due(at(n)) ? at(n) : null;
      } else if (status == SubscriptionStatus.active && period != null) {
        // Each charge of the last period comes again (several domains
        // renewing on their own dates): the soonest of them; not one that
        // a later charge already renewed (a renewal a day or two early). A
        // charge due today is still to come until the day ends.
        final renewedSince = period.days * 3 ~/ 4;
        final again = [
          for (final (i, r) in charges.indexed)
            if (!charges
                    .take(i)
                    .any(
                      (c) =>
                          c.email.at.difference(r.email.at).inDays >=
                          renewedSince,
                    ) &&
                due(period.after(r.email.at)))
              period.after(r.email.at),
        ]..sort();
        next = again.firstOrNull;
        if (next == null) {
          var n = 1;
          do {
            next = period.after(lastCharge, n++);
          } while (!due(next));
        }
      }
      found.add(
        Subscription(
          company: company,
          name: name,
          records: List.unmodifiable(records),
          cadence: cadence,
          period: period,
          amount: amount,
          status: status,
          nextCharge: next,
          variable: variable,
          spentLastYear: variable ? _spentLastYear(charges, now) : null,
          endsOn: status == SubscriptionStatus.cancelled
              ? endDateIn(cancellation!.email.text, cancellation.email.at)
              : null,
          billers: billers.length > 1 ? billers : const {},
        ),
      );
    }
    found.sort((a, b) {
      final byStatus = a.status.index.compareTo(b.status.index);
      if (byStatus != 0) return byStatus;
      final at = a.records.first.email.at;
      return b.records.first.email.at.compareTo(at);
    });
    return found;
  }

  /// Charges this close together are one bill sent twice (the bill, then
  /// the payment; or a copy without the amount).
  static const sameBill = Duration(days: 3);

  /// A bill and a payment this soon after it are one charge: the bill,
  /// then the auto-debit or the payment the user made.
  static const billToPayment = Duration(days: 16);

  static final _billNoticeSubject = RegExp(
    r'\b(?:e-?bills?|bills?|invoices?|statements?)\b',
    caseSensitive: false,
  );

  static final _paidSubject = RegExp(
    r'\b(?:paid|payments?|receipts?|deducted|debited|charged|'
    r'successful(?:ly)?|thank(?:s| you))\b',
    caseSensitive: false,
  );

  /// A bill sent before it is paid ("Your March utilities bill is
  /// ready"), not a receipt for its payment.
  static bool _isBillNotice(SubscriptionEmail email) =>
      _billNoticeSubject.hasMatch(email.subject) &&
      !_paidSubject.hasMatch(email.subject) &&
      !_moneyTaken.hasMatch(email.text);

  /// [charges] and [records] with each bill that a payment of it follows
  /// within [billToPayment] (the same amount, or the bill shows none)
  /// counted as a notice: the payment is the charge.
  static List<SubscriptionRecord> _billsPaidLater(
    List<SubscriptionRecord> charges,
    List<SubscriptionRecord> records,
  ) {
    final payments = [
      for (final r in charges)
        if (r.amount != null && !_isBillNotice(r.email)) r,
    ];
    final paid = <SubscriptionRecord>{
      for (final r in charges)
        if (_isBillNotice(r.email) &&
            payments.any((p) {
              final gap = p.email.at.difference(r.email.at);
              return gap > Duration.zero &&
                  gap <= billToPayment &&
                  (r.amount == null || r.amount == p.amount);
            }))
          r,
    };
    if (paid.isEmpty) return charges;
    for (final r in paid) {
      final i = records.indexOf(r);
      if (i >= 0) {
        records[i] = SubscriptionRecord(
          r.email,
          SubscriptionEvent.notice,
          null,
        );
      }
    }
    return [
      for (final r in charges)
        if (!paid.contains(r)) r,
    ];
  }

  /// [charges] (newest first) with each receipt that has no price and
  /// comes within [sameBill] of another charge counted as a notice about
  /// it, not a charge of its own. [records] is updated to match.
  static List<SubscriptionRecord> _oneChargePerBill(
    List<SubscriptionRecord> all,
    List<SubscriptionRecord> records,
  ) {
    final charges = _billsPaidLater(all, records);
    final kept = [
      for (final r in charges)
        if (r.amount != null) r,
    ];
    for (final r in charges.reversed) {
      if (r.amount != null) continue;
      final twin = kept.any(
        (k) => k.email.at.difference(r.email.at).abs() <= sameBill,
      );
      if (!twin) {
        kept.add(r);
        continue;
      }
      final i = records.indexOf(r);
      if (i >= 0) {
        records[i] = SubscriptionRecord(
          r.email,
          SubscriptionEvent.notice,
          null,
        );
      }
    }
    return kept..sort((a, b) => b.email.at.compareTo(a.email.at));
  }

  /// What [charges] (newest first) add up to over the last 12 months,
  /// in the newest currency; null without a year of receipts.
  static Money? _spentLastYear(List<SubscriptionRecord> charges, DateTime now) {
    final priced = [
      for (final r in charges)
        if (r.amount != null) r,
    ];
    if (priced.isEmpty ||
        now.difference(priced.last.email.at) < const Duration(days: 330)) {
      return null;
    }
    final currency = priced.first.amount!.currency;
    final since = now.subtract(const Duration(days: 365));
    var total = 0;
    for (final r in priced) {
      if (r.email.at.isAfter(since) && r.amount!.currency == currency) {
        total += r.amount!.minor;
      }
    }
    return total == 0 ? null : Money(total, currency);
  }

  static Money? _average(List<Money> amounts) => amounts.isEmpty
      ? null
      : Money(
          (amounts.fold(0, (sum, a) => sum + a.minor) / amounts.length).round(),
          amounts.first.currency,
        );

  /// The periods charges are matched against, shortest first.
  static const _calendarPeriods = [
    BillingPeriod.weekly,
    BillingPeriod(2, PeriodUnit.week),
    BillingPeriod.monthly,
    BillingPeriod.months(2),
    BillingPeriod.quarterly,
    BillingPeriod.halfYearly,
    BillingPeriod.yearly,
  ];

  /// A regular interval between charges (dates in any order), when the
  /// gaps agree: the median gap near a period, every gap within 40% of
  /// it (28 to 31 days is a month; a renewal a day late still counts).
  /// Monthly-looking charges that keep the same number of days between
  /// them while drifting against the calendar (every 30 days: 10 Jan, 9
  /// Feb, 11 Mar) are that many days.
  static BillingPeriod? _periodFromDates(List<DateTime> dates) {
    final days = <DateTime>{
      for (final d in dates) DateTime.utc(d.year, d.month, d.day),
    }.toList()..sort();
    if (days.length < 2) return null;
    final gaps = [
      for (var i = 1; i < days.length; i++)
        days[i].difference(days[i - 1]).inDays,
    ];
    final median = ([...gaps]..sort())[gaps.length ~/ 2];
    for (final p in _calendarPeriods) {
      final d = p.days;
      if ((median - d).abs() > d * 0.2 + 2 ||
          !gaps.every((g) => (g - d).abs() <= d * 0.4 + 2)) {
        continue;
      }
      if (p == BillingPeriod.monthly && gaps.length >= 2) {
        var calendar = 0;
        var fixed = 0;
        for (var i = 1; i < days.length; i++) {
          calendar += p.after(days[i - 1]).difference(days[i]).inDays.abs();
          fixed += (gaps[i - 1] - median).abs();
        }
        final margin = (gaps.length + 1) ~/ 2;
        if (fixed <= gaps.length ~/ 2 &&
            calendar >= 2 &&
            calendar - fixed >= margin) {
          return _ofDays(median) ?? p;
        }
      }
      return p;
    }
    return null;
  }

  /// The period from a charge on [from] to the next one stated for [to].
  static BillingPeriod? _periodUntil(DateTime from, DateTime to) =>
      _periodFromDates([from, to]) ??
      _ofDays(
        to.difference(DateTime.utc(from.year, from.month, from.day)).inDays,
      );

  /// What a bill says of itself in its subject.
  static final _billSubject = RegExp(
    r'\b(?:bill|e-?bill|invoice|statement|renew\w*|subscription|membership)\b',
    caseSensitive: false,
  );

  /// Charges that look like one plan billed again and again: bills or
  /// invoices, or the same price each time; not shop orders.
  static bool _steady(List<SubscriptionRecord> charges) {
    if (charges.any((r) => isShopOrder(r.email))) return false;
    if (charges.every((r) => _billSubject.hasMatch(r.email.subject))) {
      return true;
    }
    final prices = {for (final r in charges) ?r.amount};
    return prices.length <= 1;
  }

  /// What to call the subscription keyed [company] with [list]: the
  /// merchant for an app store's ("Acme via Google Play"), else [_name].
  static String _nameOf(String company, List<SubscriptionEmail> list) {
    const store = ' via Google Play';
    if (company.endsWith(store)) {
      return company.substring(0, company.length - store.length);
    }
    return _name(company, list);
  }

  /// Words a brand's other domains add to its name: its group, its
  /// billing or payments arm (`examplepower.com`, `examplepowerpay.com`).
  static const _arms = [
    'notifications',
    'payments',
    'services',
    'digital',
    'billing',
    'payment',
    'global',
    'online',
    'alerts',
    'notify',
    'group',
    'ebill',
    'bills',
    'pay',
    'hq',
  ];

  /// The brand [biller] (a registrable domain) belongs to: its first
  /// label without an [_arms] word, and whether it had one. Null for a
  /// merchant billed through a service ("Acme via stripe.com").
  static ({String stem, String label, bool arm})? _brandOf(String biller) {
    if (biller.contains(' ')) return null;
    final label = biller.toLowerCase().split('.').first;
    final parts = label.split('-');
    if (parts.length > 1 && _arms.contains(parts.last)) {
      final stem = parts.sublist(0, parts.length - 1).join();
      return (stem: stem, label: label, arm: true);
    }
    for (final arm in _arms) {
      if (label.length - arm.length >= 2 && label.endsWith(arm)) {
        final stem = label.substring(0, label.length - arm.length);
        return (stem: stem.replaceAll('-', ''), label: label, arm: true);
      }
    }
    return (stem: label.replaceAll('-', ''), label: label, arm: false);
  }

  /// [byCompany]'s mail, with the sister domains of one brand together:
  /// a biller and its payments arm (`examplepower.com` sends the bill,
  /// `examplepowerpay.com` the auto-debit receipt). The same name under
  /// another country's domain stays apart: often another service of the
  /// brand (its mobile and its home broadband). Each keyed by the first
  /// of its billers, in order.
  static List<
    ({String company, Set<String> billers, List<SubscriptionEmail> list})
  >
  _withSisters(Map<String, List<SubscriptionEmail>> byCompany) {
    final billers = byCompany.keys.toList()..sort();
    final group = {for (final b in billers) b: b};
    String root(String b) {
      var r = b;
      while (group[r] != r) {
        r = group[r]!;
      }
      return r;
    }

    final brands = {for (final b in billers) b: _brandOf(b)};
    for (final (i, a) in billers.indexed) {
      final x = brands[a];
      if (x == null || x.stem.length < 2) continue;
      for (final b in billers.skip(i + 1)) {
        final y = brands[b];
        if (y == null ||
            y.stem != x.stem ||
            y.label == x.label ||
            !(x.arm || y.arm)) {
          continue;
        }
        final (ra, rb) = (root(a), root(b));
        if (ra == rb) continue;
        // Keyed by the first, so that the key stays the same.
        if (ra.compareTo(rb) < 0) {
          group[rb] = ra;
        } else {
          group[ra] = rb;
        }
      }
    }
    final merged = <String, Set<String>>{};
    for (final b in billers) {
      merged.putIfAbsent(root(b), () => {}).add(b);
    }
    return [
      for (final MapEntry(key: company, value: members) in merged.entries)
        (
          company: company,
          billers: members,
          list: [for (final b in members) ...byCompany[b]!],
        ),
    ];
  }

  /// The sender name most used (see [companyName]), else the domain.
  static String _name(String company, List<SubscriptionEmail> list) {
    final counts = <String, int>{};
    for (final e in list) {
      final n = companyName(e.senderName);
      if (n != null) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) return company;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// "Your membership has been canceled", "you've ended your
  /// subscription to Acme".
  static final _endedPlan = RegExp(
    r"\b(?:cancel(?:l)?ed|ended|terminated)\s+your\s+(?:[\w.&'’-]+\s+){0,3}"
    r'(?:subscription|membership|plan)\b|'
    r"\byour\s+(?:[\w.&'’-]+\s+){0,3}(?:subscription|membership|plan)\s+"
    r'(?:has\s+been|has|was|is|will\s+be)\s+'
    r'(?:cancel(?:l)?ed|ended|terminated)\b',
    caseSensitive: false,
  );

  static final _planSubject = RegExp(
    r'\b(?:subscriptions?|membership|plan|premium)\b',
    caseSensitive: false,
  );

  /// Not a paid plan: a newsletter, emails, a free trial.
  static final _notAPaidPlan = RegExp(
    r'\b(?:newsletters?|mailing list|e-?mails?|marketing|communications?|'
    r'trial)\b',
    caseSensitive: false,
  );

  static final _newsletter = RegExp(
    r'\b(?:newsletter|mailing list)\b',
    caseSensitive: false,
  );

  /// Whether [email], a cancellation, says a paid plan was cancelled or
  /// ended: its subject names the plan, or its text says so; not a
  /// newsletter or a free trial.
  static bool _endsPaidPlan(SubscriptionEmail email) {
    final head = email.text.length > 600
        ? email.text.substring(0, 600)
        : email.text;
    if (_notAPaidPlan.hasMatch(email.subject) || _newsletter.hasMatch(head)) {
      return false;
    }
    return _planSubject.hasMatch(email.subject) || _endedPlan.hasMatch(head);
  }

  /// Words right before the last day of a cancelled plan.
  static final _lastDayWords = RegExp(
    r'\b(?:lose|losing|until|till|through|ends?|ending|expires?|expiring|'
    r'stops?|last day|access|cancel(?:l)?ed on)\b[^.!?\n]{0,70}$',
    caseSensitive: false,
  );

  /// The last day a cancelled plan lasts, as [text] (sent at [sent])
  /// states it: "your benefits stop on May 9, 2027", "will be
  /// cancelled on 14 Mar 2027", "access until 3 May". Null when it says
  /// none.
  static DateTime? endDateIn(String text, DateTime sent) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    final sentDay = DateTime.utc(sent.year, sent.month, sent.day);
    for (final d in DueDates.datesIn(sample, reference: sent)) {
      final days = d.date.difference(sentDay).inDays;
      if (days < 0 || days > 400) continue;
      final before = sample.substring(
        d.start - 80 < 0 ? 0 : d.start - 80,
        d.start,
      );
      if (_lastDayWords.hasMatch(before)) return d.date;
    }
    return null;
  }

  static final _fromWord = RegExp(r'\bfrom\s*$', caseSensitive: false);
  static final _toWord = RegExp(
    r'^\s*(?:(?:/|per|a|an)\s*\w+\s*)?to\s*$',
    caseSensitive: false,
  );

  /// The price [text] says [current] changes to: "from $9.49/month to
  /// $10.99/month".
  static Money? _newPrice(String text, Money current) {
    final amounts = amountsIn(text).toList();
    for (var i = 0; i + 1 < amounts.length; i++) {
      final (a, b) = (amounts[i], amounts[i + 1]);
      if (a.money != current || b.money.currency != current.currency) {
        continue;
      }
      final before = text.substring(
        a.start - 12 < 0 ? 0 : a.start - 12,
        a.start,
      );
      if (_fromWord.hasMatch(before) &&
          _toWord.hasMatch(text.substring(a.end, b.start))) {
        return b.money;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- senders

  /// "Your subscription from Acme on Google Play", "You've made a
  /// purchase from Acme Inc. on Google Play".
  static final _storeMerchant = RegExp(
    r'\b(?:subscription|purchase|order)\s+from\s+'
    r"([A-Za-z0-9][\w.&'’ -]{0,40}?)\s+on\s+Google Play\b",
    caseSensitive: false,
  );

  /// "Acme LLC is increasing the price of your subscription".
  static final _storePriceChange = RegExp(
    r"\b([A-Z0-9][\w.&'’ -]{0,40}?)\s+is\s+(?:increasing|changing|raising|"
    r'lowering)\s+the\s+price\s+of\s+your\s+subscription\b',
  );

  static final _companySuffix = RegExp(
    r',?\s+(?:Inc\.?|LLC|L\.L\.C\.|Ltd\.?|Limited|Corp\.?|Corporation|'
    r'Co\.|GmbH|PBC|Pte\.?\s+Ltd\.?|S\.A\.)$',
    caseSensitive: false,
  );

  /// For an app store's mail at [company] (Google Play's, from
  /// `google.com`), the merchant it charges for, as a biller: "Acme via
  /// Google Play"; two apps' subscriptions are two subscriptions. Else
  /// null.
  static String? storeMerchantOf(String company, String subject, String text) {
    if (company.toLowerCase() != 'google.com') return null;
    final head = text.length > 3000 ? text.substring(0, 3000) : text;
    final m =
        _storeMerchant.firstMatch('$subject\n$head') ??
        _storePriceChange.firstMatch(head);
    if (m == null) return null;
    final name = m[1]!
        .trim()
        .replaceFirst(RegExp(r'^Google Play\s+'), '')
        .replaceFirst(_companySuffix, '')
        .trim();
    return name.length < 2 ? null : '$name via Google Play';
  }

  /// Payment services that send receipts on behalf of many companies,
  /// under each company's name (`Acme <invoice+statements@stripe.com>`).
  static const billingServices = {
    'stripe.com',
    'paddle.com',
    'lemonsqueezy.com',
    'fastspring.com',
    'chargebee.com',
    'recurly.com',
    'gumroad.com',
  };

  /// Who charges, for a sender at [company] (a registrable domain) named
  /// [senderName]: the domain; for a payment service sending for another
  /// company, that company ("Acme via stripe.com"), so that two
  /// companies billed through the same service are two subscriptions.
  static String billerOf(String company, String? senderName) {
    final domain = company.toLowerCase();
    if (!billingServices.contains(domain)) return company;
    final name = companyName(senderName);
    if (name == null) return company;
    // The service's own mail ("Stripe", "Paddle Billing").
    final service = domain.substring(0, domain.indexOf('.'));
    if (_letters(name).startsWith(service)) return company;
    return '$name via $domain';
  }

  static String _letters(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// A department or channel after the company's name: "Example Support
  /// Dept.", "Acme Client Services", "Shop Notifications", "Bank (Do not
  /// reply)".
  static final _departmentSuffix = RegExp(
    r'(?:\s*[-|:,–—]\s*|\s+)(?:(?:customer|client|member|account|accounts|'
    r'billing|technical|tech|help|service|services|support|security|'
    r'payments?|online|it|the)\s+)*(?:support|service|services|care|team|'
    r'dept\.?|department|desk|helpdesk|notifications?|alerts?|billing|'
    r'renewals?|accounts?|security|payments?|mailer|no-?reply|newsletter)$',
    caseSensitive: false,
  );

  static final _parenthesis = RegExp(r'\s*[(\[（【][^)\]）】]*[)\]）】]\s*$');
  static final _brackets = RegExp(r'^[\s【\[(（]+|[\s】\])）]+$');
  static final _leadingDepartment = RegExp(
    r'^(?:the\s+)?(?:support|team|billing|help)\s+(?:at|from|@)\s+',
    caseSensitive: false,
  );

  /// [senderName] as the company's name: without a department ("Support
  /// Dept.", "Client Services", "Team"), a trailing note in brackets
  /// ("(Do not reply)") or decoration ("【Airline】"). Null when nothing
  /// is left, or the name is an address.
  static String? companyName(String? senderName) {
    var n = senderName?.trim() ?? '';
    if (n.isEmpty || n.contains('@')) return null;
    String strip(String s, RegExp re) {
      final t = s.replaceFirst(re, '').trim();
      return t.length >= 2 ? t : s;
    }

    for (var i = 0; i < 3; i++) {
      final before = n;
      n = strip(n, _parenthesis);
      n = strip(n, _leadingDepartment);
      n = strip(n, _departmentSuffix);
      if (n == before) break;
    }
    n = n.replaceAll(_brackets, '').trim();
    return n.isEmpty ? null : n;
  }
}
