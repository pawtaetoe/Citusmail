// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';

import 'subscriptions.dart' show SubscriptionFinder;

/// One email that may be about a shipped order: an order confirmation, a
/// shipping notice, a carrier's update.
final class DeliveryEmail {
  const DeliveryEmail({
    required this.messageId,
    required this.shop,
    required this.senderName,
    required this.subject,
    required this.text,
    required this.at,
    this.parcels = const [],
    this.orders = const [],
    this.bulk = false,
  });

  /// The stored message, to open it.
  final int messageId;

  /// The sender's registrable domain (`shopee.sg`).
  final String shop;

  /// The sender's display name, if any ("Shopee").
  final String? senderName;
  final String subject;

  /// What is known of the body: the preview, or the whole text once the
  /// message was downloaded. May be empty.
  final String text;
  final DateTime at;

  /// schema.org data in the email's HTML (see mail_extract), when its
  /// body is on the device.
  final List<ParcelDeliveryInfo> parcels;
  final List<OrderInfo> orders;

  /// Sorted as a newsletter or promotion (shops' shipping mail often is,
  /// for its unsubscribe link): status words count only with an order or
  /// tracking number ("Arriving soon: our new collection" does not).
  final bool bulk;
}

/// A delivery company, and its tracking page when it has a stable one.
final class Carrier {
  const Carrier._(
    this.name,
    this._pattern,
    this._domains, [
    this._template,
    this._exact,
  ]);

  /// How to call it ("Ninja Van").
  final String name;

  /// Its names, any case.
  final String _pattern;

  /// Names that count only in this case ("UPS", not "ups").
  final String? _exact;
  final List<String> _domains;

  /// The tracking page, `{n}` standing for the tracking number.
  final String? _template;

  static const ups = Carrier._(
    'UPS',
    r'\bUnited Parcel Service\b',
    ['ups.com'],
    'https://www.ups.com/track?tracknum={n}',
    r'\bUPS\b',
  );
  static const fedex = Carrier._('FedEx', r'\bfed ?ex\b|\bfederal express\b', [
    'fedex.com',
  ], 'https://www.fedex.com/fedextrack/?trknbr={n}');
  static const usps = Carrier._(
    'USPS',
    r'\bUSPS\b|\bU\.S\. Postal\b|\bUnited States Postal\b',
    ['usps.com'],
    'https://tools.usps.com/go/TrackConfirmAction?tLabels={n}',
  );
  static const dhl = Carrier._(
    'DHL',
    r'\bDHL\b',
    ['dhl.com', 'dhl.de'],
    'https://www.dhl.com/global-en/home/tracking/tracking-express.html?submit=1&tracking-id={n}',
  );
  static const singPost = Carrier._(
    'SingPost',
    r'\bsing ?post\b|\bsingapore post\b|\bspeedpost\b',
    ['singpost.com'],
    'https://www.singpost.com/track-items?trackingid={n}',
  );
  static const ninjaVan = Carrier._('Ninja Van', r'\bninja ?van\b', [
    'ninjavan.co',
  ], 'https://www.ninjavan.co/en-sg/tracking?id={n}');
  static const jnt = Carrier._(
    'J&T Express',
    r'\bJ ?& ?T\b|\bJ&amp;T\b|\bjtexpress\b',
    ['jtexpress.sg', 'jtexpress.my', 'jet.co.id'],
  );
  static const qxpress = Carrier._('Qxpress', r'\bqxpress\b', ['qxpress.net']);
  static const shopeeExpress = Carrier._(
    'Shopee Express',
    r'\bshopee express\b|\bSPX\b',
    ['spx.sg'],
  );
  static const lazadaExpress = Carrier._(
    'Lazada Express',
    r'\blazada (?:express|logistics)\b',
    [],
    null,
    r'\bLEX\b',
  );
  static const royalMail = Carrier._('Royal Mail', r'\broyal mail\b', [
    'royalmail.com',
  ], 'https://www.royalmail.com/track-your-item#/tracking-results/{n}');
  static const auPost = Carrier._(
    'Australia Post',
    r'\baustralia post\b|\bauspost\b',
    ['auspost.com.au'],
    'https://auspost.com.au/mypost/track/details/{n}',
  );

  static const all = [
    ups,
    fedex,
    usps,
    dhl,
    singPost,
    ninjaVan,
    jnt,
    qxpress,
    shopeeExpress,
    lazadaExpress,
    royalMail,
    auPost,
  ];

  RegExp get _regex =>
      _regexes[name] ??= RegExp(_pattern, caseSensitive: false);
  RegExp? get _exactRegex =>
      _exact == null ? null : _exactRegexes[name] ??= RegExp(_exact);
  static final _regexes = <String, RegExp>{};
  static final _exactRegexes = <String, RegExp>{};

  /// Whether [text] names this carrier.
  bool namedIn(String text) =>
      _regex.hasMatch(text) || (_exactRegex?.hasMatch(text) ?? false);

  /// The tracking page for [number], or null when there is no known one.
  Uri? trackingUrl(String number) {
    final t = _template;
    if (t == null) return null;
    return Uri.parse(t.replaceAll('{n}', Uri.encodeQueryComponent(number)));
  }

  /// The carrier [text] names (a markup `carrier` such as "UPS Ground"),
  /// or null.
  static Carrier? named(String text) {
    for (final c in all) {
      if (c.namedIn(text)) return c;
    }
    return null;
  }

  /// The carrier sending from [domain] (a registrable domain), or null.
  static Carrier? ofDomain(String domain) {
    final d = domain.toLowerCase();
    for (final c in all) {
      if (c._domains.contains(d)) return c;
    }
    return null;
  }

  @override
  String toString() => name;
}

/// One email, as understood.
final class DeliveryRecord {
  const DeliveryRecord({
    required this.email,
    this.status,
    this.trackingNumbers = const [],
    this.carrier,
    this.carrierName,
    this.orderNumber,
    this.expected,
    this.trackingUrl,
    this.merchant,
    this.items = const [],
  });

  final DeliveryEmail email;

  /// What the email says happened, if it says.
  final DeliveryStatus? status;

  /// Tracking numbers, normalised (upper case, no spaces).
  final List<String> trackingNumbers;
  final Carrier? carrier;

  /// The carrier's name as the email gives it, for carriers not in
  /// [Carrier.all].
  final String? carrierName;
  final String? orderNumber;

  /// The expected delivery date the email states.
  final DateTime? expected;

  /// An `https` tracking page from the email's markup.
  final Uri? trackingUrl;

  /// The shop's name from the markup.
  final String? merchant;
  final List<String> items;

  /// Whether the email alone is enough to list a delivery: markup, a
  /// tracking number, or a status past ordering in an email about an
  /// order or parcel (with its number, for bulk mail).
  bool get startsDelivery =>
      email.parcels.isNotEmpty ||
      trackingNumbers.isNotEmpty ||
      (status != null &&
          status != DeliveryStatus.ordered &&
          (orderNumber != null ||
              (!email.bulk &&
                  DeliveryFinder._aboutAnOrder.hasMatch(
                    '${email.subject}\n${email.text}',
                  ))));
}

/// A shipped order found in the mail.
final class Delivery {
  const Delivery({
    required this.key,
    required this.shop,
    required this.shopName,
    required this.records,
    required this.status,
    this.items = const [],
    this.carrier,
    this.carrierName,
    this.trackingNumber,
    this.trackingUrl,
    this.orderNumber,
    this.expected,
    this.deliveredAt,
    this.probablyDelivered = false,
    this.markedDelivered = false,
  });

  /// Stable across loads: `t:<tracking number>`, `o:<shop>:<order>` or
  /// `m:<message id>`. Used to hide it or mark it delivered.
  final String key;

  /// The shop's domain (for its picture).
  final String shop;

  /// What to call it: the shop's name.
  final String shopName;

  /// Its emails, oldest first.
  final List<DeliveryRecord> records;
  final DeliveryStatus status;
  final List<String> items;
  final Carrier? carrier;

  /// The carrier's name ([carrier]'s, or as the mail gives it).
  final String? carrierName;
  final String? trackingNumber;

  /// The carrier's tracking page: a known carrier's, else an `https`
  /// one from the markup.
  final Uri? trackingUrl;
  final String? orderNumber;

  /// When it should arrive, while on the way.
  final DateTime? expected;

  /// When it was delivered (the email that said so, or the last update
  /// for one marked or probably delivered).
  final DateTime? deliveredAt;

  /// No news for over a month while on the way: moved to delivered.
  final bool probablyDelivered;

  /// The user said it arrived.
  final bool markedDelivered;

  DateTime get lastUpdate => records.last.email.at;

  bool get arrived =>
      status == DeliveryStatus.delivered || status == DeliveryStatus.returned;
}

/// Finds shipped orders in shop and carrier mail, on the device: from
/// schema.org markup when the email has it, else from tracking numbers,
/// order numbers and status words in the subject and text.
abstract final class DeliveryFinder {
  /// Subject words of mail worth looking at (also used to pick it from
  /// the store).
  static const subjectWords = [
    'ship',
    'deliver',
    'dispatch',
    'on its way',
    'on the way',
    'out for',
    'in transit',
    'tracking',
    'parcel',
    'package',
    'shipment',
    'courier',
    'arriving',
    'arrives',
    'order',
    'returned',
    'collect',
    'pick up',
    'pickup',
  ];

  /// How long without news before one on the way is probably delivered.
  static const stale = Duration(days: 30);

  /// Emails without any number join a recent delivery from the same shop
  /// within this time.
  static const _sameShopWindow = Duration(days: 21);

  static final _aboutAnOrder = RegExp(
    r'\b(?:your|the)\s+(?:[\w&-]+\s+){0,2}'
    r'(?:order|package|parcel|shipment|item|items|delivery|purchase)s?\b',
    caseSensitive: false,
  );

  static final _shippingSubject = RegExp(
    r'\b(?:ship(?:ped|ping|ment)|deliver(?:y|ed|ing)?|dispatch(?:ed)?|'
    r'on (?:its|the|their) way|out for|in transit|tracking|parcel|package|'
    r'courier|arriving|arrives|returned)\b',
    caseSensitive: false,
  );

  /// Whether [subject] reads like shipping mail, worth downloading.
  static bool looksLikeShipping(String subject) =>
      !SubscriptionFinder.isReplyOrForward(subject) &&
      _shippingSubject.hasMatch(subject);

  // ---------------------------------------------------------------- status

  static RegExp _re(String pattern) => RegExp(pattern, caseSensitive: false);

  /// Subject wording, most telling first.
  static final _subjectStatus = <(DeliveryStatus, RegExp)>[
    (
      DeliveryStatus.returned,
      _re(
        r'\breturn(?:ed|ing)? to (?:the )?sender\b|\bbeing returned\b|'
        r'\b(?:package|parcel|shipment|order|item) (?:was |has been |is being )?returned\b',
      ),
    ),
    (
      DeliveryStatus.problem,
      _re(
        r'\bdelivery (?:attempt )?(?:failed|unsuccessful|was unsuccessful|attempted)\b|'
        r'\b(?:failed|unsuccessful|missed) (?:delivery|delivery attempt)\b|'
        r'\bwe missed you\b|\bunable to deliver\b|\bcould not (?:be )?deliver|'
        r'\bdelivery exception\b|\bdelayed\b|\bdelay\b|\bon hold\b|'
        r'\bheld (?:at|by) customs\b|\bcustoms (?:hold|clearance)\b|'
        r'\baddress (?:issue|problem)\b',
      ),
    ),
    (
      DeliveryStatus.delivered,
      _re(
        r'(?<!\b(?:will|to|be|get|gets|being|when|once) )\bdelivered\b(?! today| tomorrow)|'
        r'\b(?:has|have) arrived\b|\bwas collected\b|\bbeen collected\b',
      ),
    ),
    (
      DeliveryStatus.outForDelivery,
      _re(
        r'\bout for delivery\b|\barriv(?:ing|es) today\b|'
        r'\bdeliver(?:ed|ing|y)? today\b|\bwith (?:the|our) (?:driver|courier) today\b',
      ),
    ),
    (
      DeliveryStatus.readyForPickup,
      _re(
        r'\bready (?:for|to) (?:pick-?up|collect(?:ion)?)\b|'
        r'\bready to be collected\b|\bawaiting (?:collection|pick-?up)\b|'
        r'\bavailable for (?:pick-?up|collection)\b|'
        r'\barrived at (?:the |your )?(?:pick-?up|collection|locker|post office)',
      ),
    ),
    (
      DeliveryStatus.shipped,
      _re(
        r'\bshipped\b|\bdispatched\b|\bon (?:its|the|their) way\b|\bin transit\b|'
        r'\bhas been sent\b|\bhanded (?:over )?to\b|'
        r'\bship(?:ping|ment) (?:confirmation|notification|update)\b|'
        r'\bwill be delivered\b|\barriv(?:ing|es) (?:tomorrow|on|by|soon|\w+day)\b|'
        r'\bdelivery (?:update|scheduled)\b|\bscheduled for delivery\b|\bleft (?:our|the) (?:warehouse|facility)\b|'
        r'\btracking (?:number|information|details|update)\b',
      ),
    ),
    (
      DeliveryStatus.ordered,
      _re(
        r'\border\b[^\n]{0,30}\bconfirmed\b|'
        r'\border (?:confirmation|received|placed|is confirmed|'
        r'has been (?:placed|confirmed|received))\b|'
        r'\bthank(?:s| you) for (?:your )?(?:order|purchase)\b|'
        r"\bwe(?:'ve| have) received your order\b|\bpurchase confirmation\b",
      ),
    ),
  ];

  /// Body wording: only plain statements, as bodies also say what will
  /// happen ("we'll email you when it has shipped").
  static final _textStatus = <(DeliveryStatus, RegExp)>[
    (
      DeliveryStatus.returned,
      _re(r'\b(?:is being|has been|was|will be) returned to (?:the )?sender\b'),
    ),
    (
      DeliveryStatus.problem,
      _re(
        r'\bdelivery attempt (?:was )?(?:unsuccessful|failed)\b|'
        r'\bwe (?:tried|attempted) to deliver\b|\bwe missed you\b|'
        r'\bunable to deliver\b|\bcould not be delivered\b',
      ),
    ),
    (
      DeliveryStatus.delivered,
      _re(
        r'\b(?:has|have) been (?:successfully )?delivered\b|\b(?:was|were) delivered\b',
      ),
    ),
    (DeliveryStatus.outForDelivery, _re(r'\b(?:is|are) out for delivery\b')),
    (
      DeliveryStatus.readyForPickup,
      _re(r'\b(?:is|are) ready (?:for|to) (?:pick-?up|collect(?:ion)?)\b'),
    ),
    (
      DeliveryStatus.shipped,
      _re(
        r'\b(?:has|have) (?:been )?(?:shipped|dispatched)\b|'
        r'\b(?:is|are) on (?:its|the|their) way\b|'
        r'\b(?:has|have) been handed (?:over )?to\b|\b(?:is|are) in transit\b',
      ),
    ),
  ];

  /// "When it has shipped", "once delivered": not a statement.
  static final _conditional = _re(
    r'\b(?:when|once|after|as soon as|if|until|before)\b[^.!?\n]{0,30}$',
  );

  /// What [subject] and [text] say about the delivery: the subject's
  /// wording, else a plain statement in the text.
  static DeliveryStatus? statusOf(String subject, String text) {
    for (final (status, re) in _subjectStatus) {
      if (re.hasMatch(subject)) return status;
    }
    final sample = text.length > 4000 ? text.substring(0, 4000) : text;
    for (final (status, re) in _textStatus) {
      for (final m in re.allMatches(sample)) {
        final before = sample.substring(
          m.start - 40 < 0 ? 0 : m.start - 40,
          m.start,
        );
        if (!_conditional.hasMatch(before)) return status;
      }
    }
    return null;
  }

  // ------------------------------------------------------ tracking numbers

  /// Words that make a number nearby a tracking number.
  static final _trackingWords = _re(
    r'\btrack(?:ing)?\b|\bwaybill\b|\bAWB\b|\bconsignment\b|\bshipment\b|'
    r'\bparcel\b|\bpackage\b|\bcourier\b',
  );

  /// A label right before a number that makes it something else.
  static final _otherNumber = _re(
    r'(?:\border|\binvoice|\binv|\breceipt|\bphone|\btel|\bmobile|\bcall|'
    r'\bwhatsapp|\bfax|\bhotline|\bcode|\botp|\bpin|\baccount|\bacct|'
    r'\bref(?:erence)?|\bcustomer|\bmember|\bbooking|\btransaction|\bpo\b|'
    r'\bcard|\bcontact|\bsms)\b[^\n\d]{0,20}$',
  );

  static final _labelled = _re(
    r'\b(?:tracking|track(?:ing)? (?:no|number|id|code)|waybill|AWB|'
    r'consignment|parcel (?:no|number|id))\s*(?:no\.?|number|#|id|code)?\s*'
    r'(?:is\s*)?[:#.]?\s*#?\s*((?=[A-Z-]*\d)[A-Z0-9][A-Z0-9-]{7,29})\b',
  );

  static final _ups = RegExp(r'\b1Z[0-9A-Z]{16}\b');

  /// UPU international mail (`RR123456789SG`): the last two letters are
  /// the country of the post that sent it.
  static final _upu = RegExp(r'\b[A-Z]{2}\d{9}([A-Z]{2})\b');
  static final _ninjaVan = RegExp(r'\bNV[A-Z]{2}[A-Z0-9]{8,16}\b');
  static final _spx = RegExp(r'\bSPX[A-Z]{2}\d{8,16}\b');

  /// Letters then digits (`JTE800123456789`): a carrier's own format.
  static final _mixed = RegExp(r'\b[A-Z]{2,5}\d{8,16}[A-Z]{0,3}\b');
  static final _digits = RegExp(r'(?<![\w+-])\d{10,22}(?![\w-])');

  static const _postOf = {
    'SG': Carrier.singPost,
    'US': Carrier.usps,
    'GB': Carrier.royalMail,
    'AU': Carrier.auPost,
  };

  /// Tracking numbers in [text], each with the carrier it seems to belong
  /// to. A number counts only next to a carrier's name or a word such as
  /// "tracking" or "parcel", and not right after "order", "invoice",
  /// "phone" or "code". [sender] is the carrier that sent the email, if
  /// one did: its name need not be repeated.
  static List<({String number, Carrier? carrier})> trackingNumbersIn(
    String text, {
    Carrier? sender,
  }) {
    final sample = text.length > 30000 ? text.substring(0, 30000) : text;
    final found = <({String number, Carrier? carrier})>[];
    final seen = <String>{};

    String around(int start, int end, [int reach = 80]) => sample.substring(
      start - reach < 0 ? 0 : start - reach,
      end + reach > sample.length ? sample.length : end + reach,
    );
    bool afterOther(int start) => _otherNumber.hasMatch(
      sample.substring(start - 30 < 0 ? 0 : start - 30, start),
    );
    Carrier? carrierNear(int start, int end) =>
        Carrier.named(around(start, end)) ?? sender;

    void add(String number, Carrier? carrier) {
      final n = number.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
      if (seen.add(n)) found.add((number: n, carrier: carrier));
    }

    bool hinted(int start, int end) =>
        _trackingWords.hasMatch(around(start, end)) ||
        carrierNear(start, end) != null;

    for (final m in _ups.allMatches(sample)) {
      if (hinted(m.start, m.end)) add(m[0]!, Carrier.ups);
    }
    for (final m in _ninjaVan.allMatches(sample)) {
      if (hinted(m.start, m.end)) add(m[0]!, Carrier.ninjaVan);
    }
    for (final m in _spx.allMatches(sample)) {
      if (hinted(m.start, m.end)) add(m[0]!, Carrier.shopeeExpress);
    }
    for (final m in _upu.allMatches(sample)) {
      if (hinted(m.start, m.end) && !afterOther(m.start)) {
        add(m[0]!, carrierNear(m.start, m.end) ?? _postOf[m[1]]);
      }
    }
    // A carrier's own letters-and-digits format: the carrier named (or
    // sending) and a word such as "parcel" nearby.
    for (final m in _mixed.allMatches(sample)) {
      if (afterOther(m.start)) continue;
      if (_ups.hasMatch(m[0]!) || _upu.hasMatch(m[0]!)) continue;
      final carrier = carrierNear(m.start, m.end);
      if (carrier != null && _trackingWords.hasMatch(around(m.start, m.end))) {
        add(m[0]!, carrier);
      }
    }
    // Digits only: the carrier must be named nearby, and the length fit.
    for (final m in _digits.allMatches(sample)) {
      if (afterOther(m.start)) continue;
      final carrier = carrierNear(m.start, m.end);
      final length = m[0]!.length;
      final fits = switch (carrier) {
        Carrier.fedex => length == 12 || length == 15 || length == 20,
        Carrier.usps => length >= 20 && length <= 22,
        Carrier.dhl => length == 10,
        null => false,
        _ => _trackingWords.hasMatch(around(m.start, m.end, 40)),
      };
      if (fits) add(m[0]!, carrier);
    }
    // "Tracking number: ABC123456789", any carrier.
    for (final m in _labelled.allMatches(sample)) {
      final n = m[1]!;
      if (RegExp(r'\d').allMatches(n).length < 5) continue;
      add(n, carrierNear(m.start, m.end));
    }
    return found.take(5).toList();
  }

  // --------------------------------------------------------- order numbers

  static final _amazonOrder = RegExp(r'\b\d{3}-\d{7}-\d{7}\b');
  static final _orderLabel = _re(
    r'\border\s*(?:no\.?|number|num|id|#)?\s*[:#]?\s*#?\s*'
    r'((?=[A-Z-]*\d)[A-Z0-9][A-Z0-9-]{3,24})\b',
  );

  /// The order number in [text] ("Order #123456", "Order ID:
  /// 2310150ABCDEF1", an Amazon `123-1234567-1234567`), or null.
  static String? orderNumberIn(String text) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    if (_amazonOrder.firstMatch(sample) case final m?) return m[0];
    for (final m in _orderLabel.allMatches(sample)) {
      final n = m[1]!;
      if (RegExp(r'\d').allMatches(n).length >= 3) return n.toUpperCase();
    }
    return null;
  }

  // -------------------------------------------------------- expected dates

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
  static const _weekdays = {
    'mon': DateTime.monday,
    'tue': DateTime.tuesday,
    'wed': DateTime.wednesday,
    'thu': DateTime.thursday,
    'fri': DateTime.friday,
    'sat': DateTime.saturday,
    'sun': DateTime.sunday,
  };

  static final _expectedWords = _re(
    r'\b(?:(?:expected|estimated|scheduled)(?: (?:delivery|arrival))?(?: date)?|'
    r'arriving|arrives|will arrive|should arrive|'
    r'delivery (?:date|by|on|between|expected)|deliver(?:ed)? (?:by|on)|'
    r'get it (?:by|on)|eta)\b[:\s]*(?:is\s+)?(?:on\s+|by\s+|between\s+|from\s+)?',
  );

  static const _month =
      r'(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?';
  static const _weekday = r'(?:(mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s*)';

  static final _dateForms = [
    // Thu, 7 Nov 2026 / 7th November
    _re('^$_weekday?(\\d{1,2})(?:st|nd|rd|th)?\\s+$_month(?:,?\\s+(\\d{4}))?'),
    // Thursday, November 7, 2026 / Nov 7
    _re('^$_weekday?$_month\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?'),
    // 2026-11-07
    _re(r'^()(\d{4})-(\d{2})-(\d{2})'),
    // today, tomorrow, Thursday
    _re(r'^(today|tomorrow|(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*)\b'),
  ];

  static final _rangeJoin = _re(r'^\s*(?:-|–|—|to|and|until)\s*');

  /// The delivery date [text] states ("Arriving Thursday, November 7",
  /// "Estimated delivery: 7 Nov", "arriving tomorrow"), read against
  /// [sent], when the email was sent. For a range, its last day.
  static DateTime? expectedIn(String text, DateTime sent) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    for (final m in _expectedWords.allMatches(sample)) {
      var rest = sample.substring(m.end);
      var date = _dateAt(rest, sent);
      if (date == null) continue;
      // "between 6 Nov and 8 Nov", "Nov 6 - Nov 8".
      rest = rest.substring(date.length);
      if (_rangeJoin.firstMatch(rest) case final j?) {
        if (_dateAt(rest.substring(j.end), sent) case final until?) {
          date = until;
        }
      }
      return date.date;
    }
    return null;
  }

  static ({DateTime date, int length})? _dateAt(String s, DateTime sent) {
    final local = sent.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    for (final (i, re) in _dateForms.indexed) {
      final m = re.firstMatch(s);
      if (m == null) continue;
      DateTime? date;
      switch (i) {
        case 0 || 1:
          final d = int.tryParse(m[i == 0 ? 2 : 3]!);
          final mo = _months[m[i == 0 ? 3 : 2]!.toLowerCase().substring(0, 3)];
          final y = m[4] == null ? null : int.tryParse(m[4]!);
          if (d == null || mo == null || d < 1 || d > 31) continue;
          date = DateTime(y ?? day.year, mo, d);
          // No year: the next such date, allowing for one a little late.
          if (y == null &&
              date.isBefore(day.subtract(const Duration(days: 60)))) {
            date = DateTime(day.year + 1, mo, d);
          }
        case 2:
          final y = int.parse(m[2]!);
          final mo = int.parse(m[3]!);
          final d = int.parse(m[4]!);
          if (mo < 1 || mo > 12 || d < 1 || d > 31) continue;
          date = DateTime(y, mo, d);
        default:
          final w = m[1]!.toLowerCase();
          if (w == 'today') {
            date = day;
          } else if (w == 'tomorrow') {
            date = day.add(const Duration(days: 1));
          } else {
            final weekday = _weekdays[w.substring(0, 3)]!;
            date = day.add(Duration(days: (weekday - day.weekday) % 7));
          }
      }
      return (date: date, length: m.end);
    }
    return null;
  }

  // ---------------------------------------------------------------- reading

  /// [email], as understood: its markup first, then its words.
  static DeliveryRecord read(DeliveryEmail email) {
    final words = '${email.subject}\n${email.text}';
    final parcels = email.parcels;
    final orders = [...email.orders, ...parcels.map((p) => p.order).nonNulls];

    final tracking = <String>[];
    Carrier? carrier;
    String? carrierName;
    for (final p in parcels) {
      if (p.trackingNumber case final n?) {
        final normal = n.toUpperCase().replaceAll(RegExp(r'\s'), '');
        if (normal.length >= 6 && !tracking.contains(normal)) {
          tracking.add(normal);
        }
      }
      if (p.carrier case final c?) {
        carrierName ??= c;
        carrier ??= Carrier.named(c);
      }
    }
    if (tracking.isEmpty) {
      for (final t in trackingNumbersIn(
        words,
        sender: Carrier.ofDomain(email.shop),
      )) {
        tracking.add(t.number);
        carrier ??= t.carrier;
      }
    }
    // Else the sender, or the first carrier the email names ("dispatched
    // with Ninja Van").
    carrier ??=
        Carrier.ofDomain(email.shop) ??
        Carrier.named(words.length > 3000 ? words.substring(0, 3000) : words);

    final markupStatus = [
      ...parcels.map((p) => p.status),
      ...orders.map((o) => o.status),
    ].nonNulls.firstOrNull;
    final wordStatus = statusOf(email.subject, email.text);
    // Markup that only says "processing" on a shipping email.
    final status =
        markupStatus == null ||
            (markupStatus == DeliveryStatus.ordered &&
                wordStatus != null &&
                wordStatus != DeliveryStatus.ordered)
        ? wordStatus
        : markupStatus;

    final expected =
        parcels
            .map((p) => p.expectedUntil ?? p.expectedFrom)
            .nonNulls
            .firstOrNull ??
        expectedIn(words, email.at);

    return DeliveryRecord(
      email: email,
      status: status,
      trackingNumbers: tracking,
      carrier: carrier,
      carrierName: carrier?.name ?? carrierName,
      orderNumber:
          orders
              .map((o) => o.orderNumber)
              .nonNulls
              .firstOrNull
              ?.toUpperCase() ??
          orderNumberIn(words),
      expected: expected,
      trackingUrl: parcels.map((p) => p.trackingUrl).nonNulls.firstOrNull,
      merchant: orders.map((o) => o.merchant).nonNulls.firstOrNull,
      items: [
        ...{
          for (final p in parcels) ...p.items,
          for (final o in orders) ...o.items,
        },
      ],
    );
  }

  // ---------------------------------------------------------------- finding

  /// The deliveries in [emails] (any order): emails with the same
  /// tracking number are one delivery; else the same order number from
  /// the same shop. [now] is today; [markedDelivered] holds the keys of
  /// those the user said arrived. Newest first.
  static List<Delivery> find(
    Iterable<DeliveryEmail> emails, {
    required DateTime now,
    Set<String> markedDelivered = const {},
  }) {
    final records = [
      for (final e in emails)
        if (!SubscriptionFinder.isReplyOrForward(e.subject)) read(e),
    ]..sort((a, b) => a.email.at.compareTo(b.email.at));

    String orderKey(DeliveryRecord r) =>
        'o:${r.email.shop.toLowerCase()}:${r.orderNumber}';

    // Which tracked parcels each order was shipped in.
    final parcelsOfOrder = <String, Set<String>>{};
    for (final r in records) {
      if (r.orderNumber == null) continue;
      for (final t in r.trackingNumbers) {
        parcelsOfOrder.putIfAbsent(orderKey(r), () => {}).add('t:$t');
      }
    }

    final groups = <String, List<DeliveryRecord>>{};
    final shopGroups = <String, List<String>>{};
    void addTo(String key, DeliveryRecord r) {
      final list = groups.putIfAbsent(key, () => []);
      if (!list.contains(r)) list.add(r);
      final keys = shopGroups.putIfAbsent(r.email.shop.toLowerCase(), () => []);
      keys
        ..remove(key)
        ..add(key);
    }

    for (final r in records) {
      if (r.trackingNumbers.isNotEmpty) {
        for (final t in r.trackingNumbers) {
          addTo('t:$t', r);
        }
      } else if (r.orderNumber != null) {
        final key = orderKey(r);
        final parcels = parcelsOfOrder[key];
        if (parcels != null) {
          for (final t in parcels) {
            addTo(t, r);
          }
        } else {
          addTo(key, r);
        }
      } else if (r.startsDelivery) {
        // No number: the shop's latest delivery, if recent and not
        // arrived; else one of its own.
        final recent = shopGroups[r.email.shop.toLowerCase()]?.lastOrNull;
        final list = recent == null ? null : groups[recent];
        if (list != null &&
            r.email.at.difference(list.last.email.at) < _sameShopWindow &&
            !_arrivedStatus(_latestStatus(list))) {
          addTo(recent!, r);
        } else {
          addTo('m:${r.email.messageId}', r);
        }
      }
    }

    final found = <Delivery>[
      for (final MapEntry(:key, value: list) in groups.entries)
        if (list.any((r) => r.startsDelivery))
          _delivery(key, list, now, markedDelivered.contains(key)),
    ]..sort((a, b) => b.lastUpdate.compareTo(a.lastUpdate));
    return found;
  }

  static bool _arrivedStatus(DeliveryStatus? s) =>
      s == DeliveryStatus.delivered || s == DeliveryStatus.returned;

  /// The latest status of [list] (oldest first); an order confirmation
  /// never takes back a later stage.
  static DeliveryStatus? _latestStatus(List<DeliveryRecord> list) {
    DeliveryStatus? status;
    for (final r in list) {
      final s = r.status;
      if (s == null) continue;
      if (s == DeliveryStatus.ordered && status != null) continue;
      status = s;
    }
    return status;
  }

  static Delivery _delivery(
    String key,
    List<DeliveryRecord> list,
    DateTime now,
    bool marked,
  ) {
    var status = _latestStatus(list) ?? DeliveryStatus.shipped;
    final last = list.last.email.at;
    DateTime? deliveredAt = _arrivedStatus(status)
        ? list.lastWhere((r) => r.status == status).email.at
        : null;
    var probably = false;
    var markedNow = false;
    if (!_arrivedStatus(status) && marked) {
      status = DeliveryStatus.delivered;
      deliveredAt = last;
      markedNow = true;
    } else if (status.onTheWay &&
        status != DeliveryStatus.problem &&
        now.difference(last) > stale) {
      status = DeliveryStatus.delivered;
      deliveredAt = last;
      probably = true;
    }
    T? newest<T extends Object>(T? Function(DeliveryRecord r) f) =>
        list.reversed.map<T?>(f).nonNulls.firstOrNull;

    final tracking = key.startsWith('t:')
        ? key.substring(2)
        : newest((r) => r.trackingNumbers.firstOrNull);
    final carrier = newest((r) => r.carrier);
    // The shop: not the carrier sending updates.
    final shopMail = list.where((r) => Carrier.ofDomain(r.email.shop) == null);
    final from = shopMail.isEmpty ? list : shopMail.toList();
    return Delivery(
      key: key,
      shop: from.last.email.shop,
      shopName: newest((r) => r.merchant) ?? _name(from),
      records: List.unmodifiable(list),
      status: status,
      items: [
        ...{for (final r in list) ...r.items},
      ],
      carrier: carrier,
      carrierName: carrier?.name ?? newest((r) => r.carrierName),
      trackingNumber: tracking,
      trackingUrl:
          (tracking == null ? null : carrier?.trackingUrl(tracking)) ??
          newest((r) => r.trackingUrl),
      orderNumber: newest((r) => r.orderNumber),
      expected: status.onTheWay ? newest((r) => r.expected) : null,
      deliveredAt: deliveredAt,
      probablyDelivered: probably,
      markedDelivered: markedNow,
    );
  }

  /// The sender name most used, else the domain.
  static String _name(Iterable<DeliveryRecord> list) {
    final counts = <String, int>{};
    for (final r in list) {
      final n = r.email.senderName?.trim();
      if (n != null && n.isNotEmpty) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) return list.last.email.shop;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}
