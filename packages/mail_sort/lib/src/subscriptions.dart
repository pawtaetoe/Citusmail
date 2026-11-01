// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
  final int messageId;

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

/// How often a subscription charges.
enum Cadence {
  weekly(7),
  monthly(30),
  quarterly(91),
  yearly(365);

  const Cadence(this.days);

  /// The usual number of days between charges.
  final int days;

  /// Charges per month, for a monthly total.
  double get perMonth => switch (this) {
    weekly => 52 / 12,
    monthly => 1,
    quarterly => 1 / 3,
    yearly => 1 / 12,
  };

  Duration get period => Duration(days: days);
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
  });

  final String company;

  /// What to call it: the sender's name most used, else the domain.
  final String name;

  /// Its emails, newest first.
  final List<SubscriptionRecord> records;

  /// Null when it can't be told (one receipt, no wording about it).
  final Cadence? cadence;

  /// The latest amount charged, if any was found.
  final Money? amount;
  final SubscriptionStatus status;

  /// Estimated from the last charge and the cadence, for active ones.
  final DateTime? nextCharge;

  DateTime? get lastCharge => records
      .where((r) => r.event == SubscriptionEvent.charge)
      .map((r) => r.email.at)
      .firstOrNull;

  /// The amount per month (for a total), or null.
  Money? get monthly {
    final a = amount;
    final c = cadence;
    if (a == null || c == null) return null;
    return Money((a.minor * c.perMonth).round(), a.currency);
  }

  /// The amount per year, or null.
  Money? get yearly {
    final a = amount;
    final c = cadence;
    if (a == null || c == null) return null;
    return Money((a.minor * c.perMonth * 12).round(), a.currency);
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
  ];

  static final _subscriptionWords = RegExp(
    r'\b(?:subscriptions?|subscribed|membership|renews?|renewed|renewal|'
    r'auto-renew\w*|recurring|your plan|premium plan|billing period|'
    r'next billing|next payment|free trial|trial|'
    r'unused time on|remaining time on)\b',
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
    r'paid|charged|renewed|order confirmation|your order|billing statement)\b',
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
      r'\b(?:yearly|annual(?:ly)?|per year|/\s?y(?:ea)?r|a year|every year|12 months)\b',
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
        final length = to.difference(from);
        if (length.inDays >= 6 && length.inDays <= 400) return length;
      }
    }
    return null;
  }

  static Cadence? _cadenceOfPeriod(Duration period) {
    for (final c in Cadence.values) {
      if ((period.inDays - c.days).abs() <= c.days * 0.1 + 2) return c;
    }
    return null;
  }

  /// Whether [email] itself is about a subscription: its wording, or a
  /// billing period.
  static bool _speaksOfSubscription(SubscriptionEmail email) =>
      _subscriptionWords.hasMatch(email.subject) ||
      _subscriptionWords.hasMatch(email.text) ||
      billingPeriodIn(email.text) != null;

  /// What [email] says.
  static SubscriptionEvent eventOf(SubscriptionEmail email) {
    final subject = email.subject;
    if (_cancelWords.hasMatch(subject)) {
      // "Your order was cancelled" is about an order.
      return _orderWords.hasMatch(subject) &&
              !_subscriptionWords.hasMatch(subject)
          ? SubscriptionEvent.notice
          : SubscriptionEvent.cancelled;
    }
    if (_trialWords.hasMatch(subject)) return SubscriptionEvent.trial;
    if (_chargeWords.hasMatch(subject)) return SubscriptionEvent.charge;
    if (_cancelWords.hasMatch(email.text)) return SubscriptionEvent.cancelled;
    return SubscriptionEvent.notice;
  }

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

  /// Words right before the amount actually paid.
  static final _paidWords = RegExp(
    r'\b(?:amount (?:paid|charged)|you paid|total paid|total charged|'
    r'grand total|total due|amount due)\W*$',
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
      byCompany.putIfAbsent(e.company, () => []).add(e);
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
      final regular =
          charges.length >= 3 &&
          _cadenceFromDates([for (final r in charges) r.email.at]) != null;
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
      final cadence =
          _cadenceFromDates([for (final r in charges) r.email.at]) ??
          _cadenceFromWords([for (final r in records) r.email]);
      final says = records.any((r) => _speaksOfSubscription(r.email));
      if (!says && !regular) continue;
      if (charges.isEmpty &&
          !records.any((r) => r.event == SubscriptionEvent.trial)) {
        continue; // talk of plans, but nothing paid or started
      }

      final lastCharge = charges.firstOrNull?.email.at;
      final cancelledAt = records
          .where((r) => r.event == SubscriptionEvent.cancelled)
          .map((r) => r.email.at)
          .firstOrNull;
      final period = (cadence ?? Cadence.monthly).period;
      final SubscriptionStatus status;
      if (cancelledAt != null &&
          (lastCharge == null || cancelledAt.isAfter(lastCharge))) {
        status = SubscriptionStatus.cancelled;
      } else if (lastCharge != null &&
          now.difference(lastCharge) > period * 1.5 + const Duration(days: 7)) {
        status = SubscriptionStatus.lapsed;
      } else {
        status = SubscriptionStatus.active;
      }
      DateTime? next;
      if (status == SubscriptionStatus.active &&
          lastCharge != null &&
          cadence != null) {
        next = lastCharge.add(cadence.period);
        while (next!.isBefore(now)) {
          next = next.add(cadence.period);
        }
      }
      found.add(
        Subscription(
          company: company,
          name: _name(company, list),
          records: List.unmodifiable(records),
          cadence: cadence,
          amount: charges.map((r) => r.amount).nonNulls.firstOrNull,
          status: status,
          nextCharge: next,
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

  /// A regular interval between charges (dates newest first), when the
  /// gaps agree: the median gap near a cadence, every gap within 40% of it.
  static Cadence? _cadenceFromDates(List<DateTime> dates) {
    final days = <DateTime>{
      for (final d in dates) DateTime.utc(d.year, d.month, d.day),
    }.toList()..sort();
    if (days.length < 2) return null;
    final gaps = [
      for (var i = 1; i < days.length; i++)
        days[i].difference(days[i - 1]).inDays,
    ]..sort();
    final median = gaps[gaps.length ~/ 2];
    for (final c in Cadence.values) {
      if ((median - c.days).abs() <= c.days * 0.2 + 2 &&
          gaps.every((g) => (g - c.days).abs() <= c.days * 0.4 + 2)) {
        return c;
      }
    }
    return null;
  }

  static Cadence? _cadenceFromWords(List<SubscriptionEmail> list) {
    for (final e in list) {
      if (billingPeriodIn(e.text) case final period?) {
        if (_cadenceOfPeriod(period) case final c?) return c;
      }
    }
    for (final e in list) {
      final text = '${e.subject}\n${e.text}';
      for (final MapEntry(key: cadence, value: words)
          in _cadenceWords.entries) {
        if (words.hasMatch(text)) return cadence;
      }
    }
    return null;
  }

  /// The sender name most used, else the domain.
  static String _name(String company, List<SubscriptionEmail> list) {
    final counts = <String, int>{};
    for (final e in list) {
      final n = e.senderName?.trim();
      if (n != null && n.isNotEmpty) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) return company;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}
