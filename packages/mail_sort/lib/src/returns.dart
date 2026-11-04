// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';

import 'deliveries.dart';
import 'due_dates.dart';
import 'subscriptions.dart' show SubscriptionFinder;

/// What a return deadline was counted from.
enum ReturnBasis {
  /// The shop gave the last day ("free returns until 15 Dec 2026").
  stated,

  /// Days from delivery ("within 30 days of delivery"), and the delivery
  /// date is known.
  delivery,

  /// Days from the order: the policy says so, or says nothing, or counts
  /// from delivery but the delivery date is not known.
  order,
}

/// A return policy one email states: a last day, or a number of days.
final class ReturnPolicy {
  const ReturnPolicy({
    required this.quote,
    this.until,
    this.days,
    this.fromDelivery = false,
  });

  /// The last day to return (a calendar day, midnight UTC).
  final DateTime? until;

  /// Or how many days there are to return.
  final int? days;

  /// Whether [days] count from delivery ("of delivery", "of receipt").
  final bool fromDelivery;

  /// The sentence that says so, to show.
  final String quote;
}

/// An order that may still be returned (or could have been), and until
/// when.
final class ReturnWindow {
  const ReturnWindow({
    required this.key,
    required this.shop,
    required this.shopName,
    required this.deadline,
    required this.basis,
    required this.messageId,
    required this.quote,
    this.items = const [],
    this.orderNumber,
    this.days,
    this.countedFrom,
    this.fromDeliveryUnknown = false,
    this.deliveryKey,
  });

  /// Stable across loads: the delivery's key when it belongs to one
  /// (`t:…`, `o:…`), else `o:<shop>:<order>` or `m:<message id>`. Used to
  /// remember "Returned" and "Keeping it".
  final String key;

  /// The shop's domain (for its picture).
  final String shop;
  final String shopName;
  final List<String> items;
  final String? orderNumber;

  /// The last day to return it (a calendar day, midnight UTC).
  final DateTime deadline;
  final ReturnBasis basis;

  /// The days the policy gives, when it gives days.
  final int? days;

  /// The day [days] were counted from (delivery or order).
  final DateTime? countedFrom;

  /// The policy counts from delivery, but when it was delivered is not
  /// known, so the order date was used: the real deadline may be later.
  final bool fromDeliveryUnknown;

  /// The email that states the policy.
  final int messageId;

  /// The sentence stating it.
  final String quote;

  /// The delivery it belongs to, if any ([Delivery.key]).
  final String? deliveryKey;

  /// Days from [now]'s calendar day to [deadline]: 0 on the last day,
  /// negative once closed.
  int daysLeft(DateTime now) => deadline.difference(DueDates.dayOf(now)).inDays;
}

/// Finds return deadlines in purchase mail (order confirmations, receipts,
/// invoices, delivery emails), on the device. Only windows a shop states
/// count: "return within 30 days", "30-day returns", "free returns until
/// 15 Dec 2026", "eligible for return until …". Orders marked final sale,
/// and those already returned or refunded, are left out.
abstract final class ReturnWindows {
  /// Subject words of mail worth looking at, with
  /// [DeliveryFinder.subjectWords].
  static const subjectWords = [
    'receipt',
    'invoice',
    'purchase',
    'return',
    'refund',
  ];

  /// Longest window believed (some shops give a year).
  static const maxDays = 365;

  static RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

  static const _numberWords = {
    'seven': 7,
    'ten': 10,
    'fourteen': 14,
    'fifteen': 15,
    'thirty': 30,
    'sixty': 60,
    'ninety': 90,
  };

  static final _n = '(\\d{1,3}|${_numberWords.keys.join('|')})';

  /// Sentences: lines, ";", and "." "!" "?" before a capital.
  static final _sentenceBreak = RegExp(r'\n|;\s*|(?<=[.!?])\s+(?=[A-Z"(])');

  /// "may be returned within 14 calendar days", "returns within 15 days".
  static final _returnWithin = _re(
    '\\b(?:return(?:ed|s|able)?|send (?:it|them|items?) back|'
    'exchange[ds]?)\\b([^.\\d\\n]{0,50}?)\\b(?:with)?in\\s+$_n\\s*'
    '(?:\\(\\d+\\)\\s*)?(?:calendar\\s+|business\\s+|working\\s+)?days?\\b',
  );

  /// "Within 30 days of delivery, you can return it".
  static final _withinReturn = _re(
    '\\bwithin\\s+$_n\\s+(?:calendar\\s+)?days?\\b([^.\\n]{0,60}?)'
    '\\b(?:return|exchange|send (?:it|them) back)',
  );

  /// "30-day returns", "15 Days Free Returns", "30-day money-back
  /// guarantee", "14-day return policy".
  static final _dayReturns = _re(
    '\\b$_n[\\s-]*(?:calendar[\\s-]+)?days?\\s+'
    '(?:(?:free|easy|hassle-free|no-questions-asked)[\\s-]+)?'
    '(?:returns?|return (?:policy|window|period)|money[\\s-]back|'
    'refund (?:policy|guarantee)|exchanges?|exchange policy)\\b',
  );

  /// "you have 30 days to return".
  static final _haveDays = _re(
    '\\b(?:you have|you\'ve got|you get|there are)\\s+$_n\\s+'
    '(?:calendar\\s+)?days?\\s+to\\s+(?:return|exchange|send)',
  );

  /// "return window of 30 days", "return period: 14 days".
  static final _windowOf = _re(
    '\\b(?:return|refund|exchange) (?:window|period)\\b[^.\\d\\n]{0,25}?'
    '\\b$_n\\s*(?:calendar\\s+)?days?\\b',
  );

  /// Processing times, not windows ("returns are processed within 5
  /// business days", "refund credited within 7 days").
  static final _processing = _re(
    r'\b(?:credit\w*|process\w*|issu\w*|reflect\w*|appear\w*|'
    r'inspect\w*|review\w*|take|takes)\b',
  );

  /// What the days count from, right after them.
  static final _from = _re(
    r'^[^.\n]{0,30}?\b(?:of|from|after|upon|following)\s+(?:the\s+)?'
    r'(?:date\s+(?:of\s+)?)?(?:your\s+|the\s+)?'
    r'(deliver\w*|receiv\w*|receipt|arriv\w*|you (?:receive|get)\w*|'
    r'purchase\w*|order\w*|invoice|dispatch\w*|ship\w*)',
  );

  static final _deliveryWords = _re(r'^(?:deliver|receiv|receipt|arriv|you)');

  /// Words right before a last day: "Return by", "free returns until",
  /// "eligible for return until", "refund window closes on".
  static final _untilWords = _re(
    r'\b(?:returns?|returned|returnable|refunds?|exchanges?|exchanged)\b'
    r'[^\d\n]{0,60}?\b(?:by|until|till|before|through|thru|no later than|'
    r'closes?|closing|ends?|expires?|deadline)\b(?:\s+on)?[\s:,]*'
    r'(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s*)?$',
  );

  /// Not returnable at all.
  static final _finalSale = _re(
    r'\b(?:final sale|non-?returnable|non-?refundable|'
    r'not (?:eligible|available|valid) for (?:a\s+)?(?:returns?|refunds?|exchanges?)|'
    r"(?:can ?not|can't|cannot|won't|will not) be (?:returned|refunded|exchanged)|"
    r'no (?:returns|refunds|exchanges)(?: or (?:exchanges|refunds))?\b(?! policy)|'
    r'all sales (?:are )?final)',
  );

  /// A final-sale note about some products, not this order ("items marked
  /// final sale", "gift cards are non-refundable").
  static final _qualified = _re(
    r'\b(?:items? marked|marked (?:as )?|except|excluding|exclusions?|'
    r'some (?:items|products)|certain|selected|unless|if (?:the|an|your)|'
    r'gift ?cards?|personali[sz]ed|customi[sz]ed|underwear|swimwear|'
    r'earrings|hygiene|perishable|digital|software|downloads?|'
    r'clearance|sale items|shipping (?:fees?|charges?|costs?)|delivery fees?)\b',
  );

  /// The order was returned or refunded: in the subject…
  static final _returnedSubject = _re(
    r'\brefund(?:ed| processed| issued| completed| confirmation)?\b|'
    r'\breturn (?:received|confirmation|confirmed|request|label|started|'
    r'approved|processed|complete[d]?|accepted|initiated)\b|'
    r'\byour return\b|\breturn of your\b',
  );

  /// …or plainly stated in the text.
  static final _returnedText = _re(
    r'\b(?:refund (?:has been|was|is being) (?:processed|issued|completed|'
    r'approved|initiated|credited)|(?:has|have) been refunded|'
    r"we(?:'ve| have) (?:received|processed) your return|"
    r"we(?:'ve| have) refunded|"
    r'your return (?:has been|was) (?:received|processed|completed|'
    r'approved|accepted))\b',
  );

  /// Purchase mail by its subject.
  static final _purchaseSubject = _re(
    r'\b(?:receipt|invoice|order\w*|purchase\w*|bought|'
    r'ship\w*|deliver\w*|dispatch\w*|tax invoice)\b',
  );

  static int? _number(String word) =>
      int.tryParse(word) ?? _numberWords[word.toLowerCase()];

  static List<String> _sentences(String text) => [
    for (final s in text.split(_sentenceBreak))
      if (s.trim().isNotEmpty) s.trim(),
  ];

  static String _quote(String sentence) => sentence.length > 200
      ? '${sentence.substring(0, 197).trimRight()}…'
      : sentence;

  /// Whether [text] says the order cannot be returned ("Final sale",
  /// "This item is non-returnable"), not just some products.
  static bool isFinalSale(String text) {
    for (final s in _sentences(_sample(text))) {
      if (_finalSale.hasMatch(s) && !_qualified.hasMatch(s)) return true;
    }
    return false;
  }

  /// Whether [subject] and [text] say an order was returned or refunded.
  static bool saysReturned(String subject, String text) =>
      (_returnedSubject.hasMatch(subject) &&
          !SubscriptionFinder.isReplyOrForward(subject)) ||
      _returnedText.hasMatch(_sample(text));

  static String _sample(String text) =>
      text.length > 20000 ? text.substring(0, 20000) : text;

  /// The return policy [text] states, read against [sent] (for dates
  /// without a year): a last day, else a number of days. Sentences about
  /// what can't be returned don't count. Null when it states none.
  static ReturnPolicy? policyIn(String text, {required DateTime sent}) {
    ReturnPolicy? days;
    for (final s in _sentences(_sample(text))) {
      if (_finalSale.hasMatch(s)) continue;
      for (final d in DueDates.datesIn(s, reference: sent)) {
        final before = s.substring(
          d.start - 80 < 0 ? 0 : d.start - 80,
          d.start,
        );
        if (_untilWords.hasMatch(before)) {
          return ReturnPolicy(until: d.date, quote: _quote(s));
        }
      }
      if (days?.fromDelivery ?? false) continue;
      final found = _daysIn(s);
      if (found == null) continue;
      if (days == null || found.fromDelivery) days = found;
    }
    return days;
  }

  static ReturnPolicy? _daysIn(String s) {
    ReturnPolicy? best;
    void consider(String number, int end) {
      final n = _number(number);
      if (n == null || n < 1 || n > maxDays) return;
      final rest = s.substring(end, end + 80 > s.length ? s.length : end + 80);
      final basis = _from.firstMatch(rest)?[1];
      final fromDelivery =
          basis != null && _deliveryWords.hasMatch(basis.toLowerCase());
      if (best == null || (fromDelivery && !best!.fromDelivery)) {
        best = ReturnPolicy(
          days: n,
          fromDelivery: fromDelivery,
          quote: _quote(s),
        );
      }
    }

    for (final m in _returnWithin.allMatches(s)) {
      if (_processing.hasMatch(m[1]!)) continue;
      consider(m[2]!, m.end);
    }
    for (final m in _withinReturn.allMatches(s)) {
      if (_processing.hasMatch(m[2]!)) continue;
      // "within 30 days of delivery, return": the basis sits in between.
      consider(m[1]!, m.start + m[0]!.indexOf(RegExp(r'days?\b')) + 3);
    }
    for (final re in [_dayReturns, _haveDays, _windowOf]) {
      for (final m in re.allMatches(s)) {
        consider(m[1]!, m.end);
      }
    }
    return best;
  }

  /// Whether [r] is a purchase email: an order confirmation, receipt,
  /// invoice or delivery email (not a shop's newsletter about its
  /// returns policy).
  static bool isPurchase(DeliveryRecord r) {
    final e = r.email;
    if (SubscriptionFinder.isReplyOrForward(e.subject)) return false;
    if (e.orders.isNotEmpty || e.parcels.isNotEmpty) return true;
    if (r.orderNumber != null || r.trackingNumbers.isNotEmpty) return true;
    if (e.bulk) return false;
    return r.status != null || _purchaseSubject.hasMatch(e.subject);
  }

  // ---------------------------------------------------------------- finding

  /// The return windows in [emails] (any order): one per order, from the
  /// policy its purchase emails state. Emails of one of [deliveries] (from
  /// [DeliveryFinder.find] on the same mail) are one order, as are those
  /// with the same order number from the same shop. A window counting
  /// "from delivery" counts from the delivery's date when it is known.
  /// Orders marked final sale, returned to the sender, or returned or
  /// refunded since are left out. Every window, closed ones too, the
  /// soonest deadline first.
  static List<ReturnWindow> find(
    Iterable<DeliveryEmail> emails, {
    List<Delivery> deliveries = const [],
  }) {
    final records = [
      for (final e in emails)
        if (!SubscriptionFinder.isReplyOrForward(e.subject))
          DeliveryFinder.read(e),
    ]..sort((a, b) => a.email.at.compareTo(b.email.at));

    final deliveryOf = <int, Delivery>{};
    final deliveryOfOrder = <String, Delivery>{};
    String orderKey(String shop, String order) =>
        'o:${shop.toLowerCase()}:$order';
    for (final d in deliveries) {
      for (final r in d.records) {
        deliveryOf[r.email.messageId] = d;
        if (r.orderNumber case final o?) {
          deliveryOfOrder[orderKey(r.email.shop, o)] = d;
        }
      }
    }

    final groups = <String, List<DeliveryRecord>>{};
    final deliveryFor = <String, Delivery>{};
    for (final r in records) {
      final order = r.orderNumber;
      final orderGroup = order == null ? null : orderKey(r.email.shop, order);
      final delivery =
          deliveryOf[r.email.messageId] ??
          (orderGroup == null ? null : deliveryOfOrder[orderGroup]);
      final key = delivery?.key ?? orderGroup ?? 'm:${r.email.messageId}';
      if (delivery != null) deliveryFor[key] = delivery;
      groups.putIfAbsent(key, () => []).add(r);
    }

    // Returns and refunds that name no order: matched by shop and item.
    final looseReturns = [
      for (final r in records)
        if (r.orderNumber == null &&
            deliveryOf[r.email.messageId] == null &&
            saysReturned(r.email.subject, r.email.text))
          r,
    ];

    final found = <ReturnWindow>[];
    for (final MapEntry(:key, value: list) in groups.entries) {
      final delivery = deliveryFor[key];
      if (delivery?.status == DeliveryStatus.returned) continue;
      if (list.any((r) => saysReturned(r.email.subject, r.email.text))) {
        continue;
      }
      final purchases = list.where(isPurchase).toList();
      if (purchases.isEmpty) continue;
      if (purchases.any(
        (r) => isFinalSale('${r.email.subject}\n${r.email.text}'),
      )) {
        continue;
      }
      // The newest email stating a policy says what holds now.
      ReturnPolicy? policy;
      DeliveryRecord? stating;
      for (final r in purchases.reversed) {
        final p = policyIn(r.email.text, sent: r.email.at);
        if (p == null) continue;
        if (policy == null ||
            (p.until != null && policy.until == null) ||
            (p.fromDelivery && !policy.fromDelivery && policy.until == null)) {
          policy = p;
          stating = r;
        }
      }
      if (policy == null || stating == null) continue;

      final items = [
        ...{...?delivery?.items, for (final r in list) ...r.items},
      ];
      final first = list.first.email;
      if (looseReturns.any(
        (r) =>
            r.email.shop.toLowerCase() == first.shop.toLowerCase() &&
            r.email.at.isAfter(first.at) &&
            items.any(
              (i) =>
                  i.length >= 6 &&
                  '${r.email.subject}\n${r.email.text}'.toLowerCase().contains(
                    i.toLowerCase(),
                  ),
            ),
      )) {
        continue;
      }

      final ordered = DueDates.dayOf(
        [
              ...list.expand((r) => r.email.orders),
              ...?delivery?.records.expand((r) => r.email.orders),
            ].map((o) => o.orderDate).nonNulls.firstOrNull ??
            [
              first.at,
              ?delivery?.records.first.email.at,
            ].reduce((a, b) => a.isBefore(b) ? a : b),
      );
      final delivered =
          delivery != null &&
              delivery.status == DeliveryStatus.delivered &&
              !delivery.probablyDelivered &&
              !delivery.markedDelivered
          ? delivery.deliveredAt
          : null;

      final DateTime deadline;
      final ReturnBasis basis;
      DateTime? from;
      if (policy.until case final until?) {
        deadline = until;
        basis = ReturnBasis.stated;
      } else if (policy.fromDelivery && delivered != null) {
        from = DueDates.dayOf(delivered);
        deadline = from.add(Duration(days: policy.days!));
        basis = ReturnBasis.delivery;
      } else {
        from = ordered;
        deadline = from.add(Duration(days: policy.days!));
        basis = ReturnBasis.order;
      }
      final email = stating.email;
      found.add(
        ReturnWindow(
          key: key,
          shop: delivery?.shop ?? email.shop,
          shopName:
              delivery?.shopName ??
              list.map((r) => r.merchant).nonNulls.firstOrNull ??
              _name(list),
          items: items,
          orderNumber:
              delivery?.orderNumber ??
              list.map((r) => r.orderNumber).nonNulls.lastOrNull,
          deadline: deadline,
          basis: basis,
          days: policy.until == null ? policy.days : null,
          countedFrom: from,
          fromDeliveryUnknown:
              policy.fromDelivery && basis == ReturnBasis.order,
          messageId: email.messageId,
          quote: policy.quote,
          deliveryKey: delivery?.key,
        ),
      );
    }
    found.sort((a, b) => a.deadline.compareTo(b.deadline));
    return found;
  }

  /// The sender name most used, else the domain.
  static String _name(List<DeliveryRecord> list) {
    final counts = <String, int>{};
    for (final r in list) {
      final n = r.email.senderName?.trim();
      if (n != null && n.isNotEmpty) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) return list.last.email.shop;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}
