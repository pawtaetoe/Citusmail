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
  });

  /// The company's domain, or for a company billed through a payment
  /// service, `Acme via stripe.com` ([SubscriptionFinder.billerOf]).
  final String company;

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

  static final _subscriptionWords = RegExp(
    r'\b(?:subscriptions?|subscribed|membership|renews?|renewed|renewal|'
    r'auto-renew\w*|recurring|your plan|premium plan|billing period|'
    r'next billing|next payment|free trial|trial|'
    r'unused time on|remaining time on|'
    // Phone, broadband and utility bills recur too.
    r'e-?bill|monthly (?:bill|invoice))\b',
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
    r'e-?bill|your (?:\w+ )?bill|bill (?:is|for))\b',
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
  /// "28 Sep 2026 - 28 Sep 2027", "2026-09-28 to 2027-09-28").
  static final _periods = [
    RegExp(
      '$_month\\s+(\\d{1,2}),?\\s+(\\d{4})\\s*(?:[-–—]|to|until)\\s*'
      '$_month\\s+(\\d{1,2}),?\\s+(\\d{4})',
      caseSensitive: false,
    ),
    RegExp(
      '(\\d{1,2})\\s+$_month,?\\s+(\\d{4})\\s*(?:[-–—]|to|until)\\s*'
      '(\\d{1,2})\\s+$_month,?\\s+(\\d{4})',
      caseSensitive: false,
    ),
    RegExp(
      r'(\d{4})-(\d{2})-(\d{2})\s*(?:[-–—]|to|until)\s*(\d{4})-(\d{2})-(\d{2})',
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
    for (final (i, re) in _periods.indexed) {
      for (final m in re.allMatches(text)) {
        DateTime? date(int g) {
          final (y, mo, d) = switch (i) {
            0 => (m[g + 2], _months[m[g]!.toLowerCase()], m[g + 1]),
            1 => (m[g + 2], _months[m[g + 1]!.toLowerCase()], m[g]),
            _ => (m[g], int.tryParse(m[g + 1]!), m[g + 2]),
          };
          final year = int.tryParse(y!);
          final day = int.tryParse(d!);
          if (year == null || mo == null || day == null) return null;
          return DateTime.utc(year, mo, day);
        }

        final from = date(1);
        final to = date(4);
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
    return _ofDays(r.to.difference(r.from).inDays);
  }

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
    r'(?:renewal|billing)\s+date)\b',
    caseSensitive: false,
  );

  /// The date of the next charge [text] states ("renews on 12 Dec 2026",
  /// "Your next renewal date is 12-04-2027"), read against [sent]; only
  /// one after [sent].
  static DateTime? renewalDateIn(String text, DateTime sent) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    final sentDay = DateTime.utc(sent.year, sent.month, sent.day);
    for (final m in _renewsOnWords.allMatches(sample)) {
      final rest = sample.substring(
        m.end,
        m.end + 40 > sample.length ? sample.length : m.end + 40,
      );
      final date = DueDates.datesIn(rest, reference: sent).firstOrNull;
      if (date == null || date.start > 12) continue;
      final days = date.date.difference(sentDay).inDays;
      if (days >= 1 && days <= 400) return date.date;
    }
    return null;
  }

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
    r'could not be (?:processed|charged)|payment (?:issue|problem))\b',
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
    if (_chargeWords.hasMatch(subject)) return SubscriptionEvent.charge;
    final text = email.text;
    // "Data plan renewal": "Your plan is renewed. Your next renewal date
    // is 12-04-2027."; "Your free trial has ended, and you're now a paid
    // member".
    if ((_renewalSubject.hasMatch(subject) && _renewedText.hasMatch(text)) ||
        _paidNow.hasMatch(text)) {
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
      first ??= money;
      final before = sample.substring(
        m.start - 40 < 0 ? 0 : m.start - 40,
        m.start,
      );
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

  /// Every amount in [text], with where it is.
  static Iterable<({Money money, int start, int end})> amountsIn(
    String text,
  ) sync* {
    for (final m in _amount.allMatches(text)) {
      if (_money(m) case final money?) {
        yield (money: money, start: m.start, end: m.end);
      }
    }
  }

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
      byCompany.putIfAbsent(billerOf(e.company, e.senderName), () => []).add(e);
    }
    final found = <Subscription>[];
    for (final MapEntry(key: company, value: list) in byCompany.entries) {
      list.sort((a, b) => b.at.compareTo(a.at));
      final records = [
        for (final e in list)
          SubscriptionRecord(
            e,
            eventOf(e),
            amountIn('${e.subject}\n${e.text}'),
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
      // Nothing paid yet (only a free trial, or talk of plans): not a
      // subscription until a charge comes.
      if (charges.isEmpty) continue;

      final lastCharge = charges.first.email.at;
      // The next charge as the newest mail since the last charge states
      // it ("renews on 12 Dec 2026", "next renewal date is 12-04-2027").
      DateTime? renewsOn;
      for (final r in records) {
        if (r.email.at.isBefore(lastCharge)) break;
        if (r.event == SubscriptionEvent.cancelled) break;
        if (renewalDateIn(r.email.text, r.email.at) case final d?) {
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
      final period =
          byKind
              .map((r) => statedPeriodIn(r.email.text))
              .nonNulls
              .firstOrNull ??
          _periodFromDates([for (final r in charges) r.email.at]) ??
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
      final cancelledAt = records
          .where((r) => r.event == SubscriptionEvent.cancelled)
          .map((r) => r.email.at)
          .firstOrNull;
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
        // renewing on their own dates): the soonest of them. A charge due
        // today is still to come until the day ends.
        final again = [
          for (final r in charges)
            if (due(period.after(r.email.at))) period.after(r.email.at),
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
          name: _name(company, list),
          records: List.unmodifiable(records),
          cadence: cadence,
          period: period,
          amount: variable ? _average(recent) : recent.firstOrNull,
          status: status,
          nextCharge: next,
          variable: variable,
          spentLastYear: variable ? _spentLastYear(charges, now) : null,
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

  /// [charges] (newest first) with each receipt that has no price and
  /// comes within [sameBill] of another charge counted as a notice about
  /// it, not a charge of its own. [records] is updated to match.
  static List<SubscriptionRecord> _oneChargePerBill(
    List<SubscriptionRecord> charges,
    List<SubscriptionRecord> records,
  ) {
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

  // ------------------------------------------------------------- senders

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
