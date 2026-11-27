// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../../inbox/state/corrections.dart';
import '../../inbox/state/message_reads.dart';
import 'found_model.dart';

/// What [findDeliveries] found: every delivery the rules found ([hidden]
/// and [learned] ones too, by key), those the user [marked] delivered,
/// the return windows in purchase mail, and the emails worth downloading
/// ([toRead]).
typedef DeliveriesFound = ({
  List<Delivery> all,
  Set<String> hidden,
  Set<String> learned,
  Set<String> marked,
  List<ReturnWindow> returns,
  List<MessageId> toRead,
});

/// The Deliveries page's findings in [store], reading text and markup off
/// the UI thread. The page and reading in the background both use it, so
/// both want the same emails. [toRead] leaves out [skip].
Future<DeliveriesFound> findDeliveries(
  MailStore store,
  DateTime now, {
  Set<MessageId> skip = const {},
}) async {
  Set<String> read(StringListSetting setting) =>
      setting.read(store.settings).toSet();
  final hidden = read(DeliveriesModel.hiddenSetting);
  final marked = read(DeliveriesModel.deliveredSetting);
  final mail = await loadDeliveryMail(store, now);
  final all = DeliveryFinder.find(
    mail.shipping,
    now: now,
    markedDelivered: marked,
  );
  final messages = {for (final m in mail.messages) m.id: m};
  final learned = await Corrections(store).vetoed(MailKind.delivery, {
    for (final d in all)
      if (!hidden.contains(d.key))
        d.key: deliverySamples(d, (id) => messages[id]),
  });
  return (
    all: all,
    hidden: hidden,
    learned: learned,
    marked: marked,
    returns: ReturnWindows.find(mail.emails, deliveries: all),
    toRead: deliveryMailToRead(
      store,
      mail.messages,
      all,
      left: {...hidden, ...learned},
      skip: skip,
    ),
  );
}

/// Where something may be missing: shipping mail of [candidates] not
/// understood yet ([all] are the deliveries found), and that of
/// deliveries on the way without a tracking number or a date (those in
/// [left] aside), not on the device. Small ones only, newsletters aside,
/// at most [DeliveriesModel.readMax]; [skip] left out.
List<MessageId> deliveryMailToRead(
  MailStore store,
  List<StoredMessage> candidates,
  List<Delivery> all, {
  required Set<String> left,
  Set<MessageId> skip = const {},
}) {
  final known = {
    for (final d in all)
      for (final r in d.records) r.email.messageId: d,
  };
  bool worthReading(StoredMessage m) => switch (known[m.id]) {
    null =>
      DeliveryFinder.looksLikeShipping(m.subject ?? '') ||
          ReturnWindows.looksLikeReceipt(m.subject ?? ''),
    final d =>
      !left.contains(d.key) &&
          !d.arrived &&
          (d.trackingNumber == null || d.expected == null),
  };
  return [
    for (final m in candidates)
      if (m.size <= DeliveriesModel.maxBytes &&
          m.category != MessageCategory.newsletters &&
          !skip.contains(m.id) &&
          !MessageReads.downloaded(store, m.id) &&
          worthReading(m))
        m.id,
  ].take(DeliveriesModel.readMax).toList();
}

/// What the classifier reads of [delivery]'s emails.
List<MailSample> deliverySamples(
  Delivery delivery,
  StoredMessage? Function(MessageId id) message,
) => [
  for (final r in delivery.records)
    mailSample(
      message(r.email.messageId),
      domain: r.email.shop,
      senderName: r.email.senderName,
      subject: r.email.subject,
      text: r.email.text,
    ),
];

/// The Deliveries page's findings, with the return windows marked
/// "Returned" and "Keeping it" (by key).
typedef DeliveriesPage = ({
  DeliveriesFound found,
  Set<String> returned,
  Set<String> kept,
});

/// The Deliveries page's data: shipped orders found in shop and carrier
/// mail, on the device. Downloaded emails are read whole, with the
/// schema.org data in their HTML; the others by their preview.
/// [readEmails] downloads shipping emails that are not on the device yet,
/// only when the user asks.
final class DeliveriesModel extends FoundModel<Delivery, DeliveriesPage> {
  DeliveriesModel(super.services, {super.now})
    : super(kind: MailKind.delivery, hiddenKeys: hiddenSetting);

  static const hiddenSetting = StringListSetting('deliveries.hidden');
  static const deliveredSetting = StringListSetting('deliveries.delivered');

  /// Return windows the user said were returned, or that they keep.
  static const returnedSetting = StringListSetting('returns.returned');
  static const keptSetting = StringListSetting('returns.kept');

  /// How far back shipping mail is looked at.
  static const lookBack = Duration(days: 365);

  /// Delivered ones stay in "Delivered" this long, then go to "Older".
  static const recent = Duration(days: 30);

  /// Shipping emails downloaded at most, small ones only.
  static const readMax = 40;
  static const maxBytes = 256 * 1024;

  Set<String> _readSet(StringListSetting setting) =>
      setting.read(store.settings).toSet();

  @override
  Future<DeliveriesPage> find(DateTime now, Set<MessageId> skip) async {
    final returned = _readSet(returnedSetting);
    final kept = _readSet(keptSetting);
    final found = await findDeliveries(store, now, skip: skip);
    return (found: found, returned: returned, kept: kept);
  }

  @override
  Finds<Delivery> findsOf(DeliveriesPage page) => (
    all: page.found.all,
    hidden: page.found.hidden,
    learned: page.found.learned,
    toRead: page.found.toRead,
  );

  @override
  String keyOf(Delivery item) => item.key;

  @override
  List<MailSample> samplesOf(Delivery item) =>
      deliverySamples(item, store.messages.byId);

  /// Every delivery not hidden, newest first.
  List<Delivery> get deliveries => listed;

  /// Deliveries the user marked delivered (by key).
  Set<String> get marked => found?.found.marked ?? const {};

  /// Return windows stated in purchase mail (closed ones too), the
  /// soonest deadline first.
  List<ReturnWindow> get returns => found?.found.returns ?? const [];

  /// Return windows marked "Returned" and "Keeping it" (by key).
  Set<String> get returned => found?.returned ?? const {};
  Set<String> get kept => found?.kept ?? const {};

  /// Not delivered yet, the soonest expected first: out for delivery and
  /// ready to collect, then by expected date, then the rest by latest
  /// news.
  List<Delivery> get onTheWay {
    final today = now();
    final list = [
      for (final d in deliveries)
        if (!d.arrived && today.difference(d.lastUpdate) <= recent) d,
    ];
    DateTime? soon(Delivery d) => switch (d.status) {
      DeliveryStatus.outForDelivery || DeliveryStatus.readyForPickup => today,
      _ => d.expected,
    };
    list.sort((a, b) {
      final x = soon(a);
      final y = soon(b);
      if (x != null && y != null) return x.compareTo(y);
      if (x != null) return -1;
      if (y != null) return 1;
      return b.lastUpdate.compareTo(a.lastUpdate);
    });
    return list;
  }

  /// Delivered or returned in the last 30 days, the latest first.
  List<Delivery> get delivered => [
    for (final d in deliveries)
      if (d.arrived && now().difference(_arrivedAt(d)) <= recent) d,
  ]..sort((a, b) => _arrivedAt(b).compareTo(_arrivedAt(a)));

  /// Everything else: delivered longer ago, or a problem with no news
  /// for a month.
  List<Delivery> get older {
    final shown = {...onTheWay, ...delivered};
    return [
      for (final d in deliveries)
        if (!shown.contains(d)) d,
    ];
  }

  static DateTime _arrivedAt(Delivery d) => d.deliveredAt ?? d.lastUpdate;

  /// Orders that can still be returned and that the user has not marked
  /// "Returned" or "Keeping it", the soonest deadline first.
  List<ReturnWindow> get canStillReturn => [
    for (final w in returns)
      if (w.daysLeft(now()) >= 0 &&
          !returned.contains(w.key) &&
          !kept.contains(w.key))
        w,
  ];

  /// Open windows marked "Returned" or "Keeping it", to list again.
  List<ReturnWindow> get doneReturns => [
    for (final w in returns)
      if (w.daysLeft(now()) >= 0 &&
          (returned.contains(w.key) || kept.contains(w.key)))
        w,
  ];

  /// The return window of the delivery with [key], if its mail states one.
  ReturnWindow? returnFor(String key) =>
      returns.where((w) => w.deliveryKey == key).firstOrNull;

  /// "Mark as delivered", for one stuck on the way (undoable).
  void markDelivered(String key) =>
      writeKeys(deliveredSetting, {...marked, key});

  void unmarkDelivered(String key) =>
      writeKeys(deliveredSetting, {...marked}..remove(key));

  /// "Returned" and "Keeping it": no longer listed under "Can still be
  /// returned" (undoable).
  void markReturned(String key) =>
      writeKeys(returnedSetting, {...returned, key});

  void markKept(String key) => writeKeys(keptSetting, {...kept, key});

  /// Listed again as one that can still be returned.
  void unmarkReturn(String key) {
    returnedSetting.write(store.settings, [
      for (final k in returned)
        if (k != key) k,
    ]);
    writeKeys(keptSetting, {...kept}..remove(key));
  }
}

/// Shop and carrier mail on the device: [messages], read as [emails];
/// [shipping] are those with shipping words in their subject (for
/// [DeliveryFinder.find]), the others receipts and invoices (for
/// [ReturnWindows.find] with them).
typedef DeliveryMail = ({
  List<StoredMessage> messages,
  List<DeliveryEmail> emails,
  List<DeliveryEmail> shipping,
});

/// Loads the last year's shop and carrier mail from [store], reading
/// text and markup off the UI thread.
Future<DeliveryMail> loadDeliveryMail(MailStore store, DateTime now) async {
  final candidates = store.messages.withSubjectWords([
    ...DeliveryFinder.subjectWords,
    ...ReturnWindows.subjectWords,
  ], since: now.subtract(DeliveriesModel.lookBack));
  final read = await _reads.read(store, candidates);
  final emails = <DeliveryEmail>[];
  final shipping = <DeliveryEmail>[];
  for (final (i, m) in candidates.indexed) {
    final from = m.from;
    if (from == null) continue;
    final email = DeliveryEmail(
      messageId: m.id,
      shop: Domains.registrable(from.domain) ?? from.domain.toLowerCase(),
      senderName: from.displayName,
      subject: m.subject ?? '',
      text: read[i].text,
      at: m.receivedAt,
      parcels: read[i].parcels,
      orders: read[i].orders,
      bulk: m.category == MessageCategory.newsletters,
    );
    emails.add(email);
    final subject = email.subject.toLowerCase();
    if (DeliveryFinder.subjectWords.any(subject.contains)) shipping.add(email);
  }
  return (messages: candidates, emails: emails, shipping: shipping);
}

/// The return windows still open that the user has not marked "Returned"
/// or "Keeping it", the soonest first (for reminders).
Future<List<ReturnWindow>> openReturnWindows(
  MailStore store,
  DateTime now,
) async {
  Set<String> read(StringListSetting setting) =>
      setting.read(store.settings).toSet();
  final done = {
    ...read(DeliveriesModel.returnedSetting),
    ...read(DeliveriesModel.keptSetting),
  };
  final mail = await loadDeliveryMail(store, now);
  final deliveries = DeliveryFinder.find(
    mail.shipping,
    now: now,
    markedDelivered: read(DeliveriesModel.deliveredSetting),
  );
  return [
    for (final w in ReturnWindows.find(mail.emails, deliveries: deliveries))
      if (w.daysLeft(now) >= 0 && !done.contains(w.key)) w,
  ];
}

typedef _Read = ({
  String text,
  List<ParcelDeliveryInfo> parcels,
  List<OrderInfo> orders,
});

/// What the Deliveries page has read of each message.
final _reads = MessageReads<_Read>(_read, size: (r) => r.text.length);

/// Each message's text (the downloaded body, capped, else its preview)
/// and the schema.org data in its raw HTML part, read before the HTML is
/// made safe to show (that drops the scripts holding JSON-LD). Nothing in
/// it is run.
List<_Read> _read(List<(Uint8List?, String?)> messages) => [
  for (final (raw, snippet) in messages)
    if (raw != null)
      () {
        try {
          final view = MessageView.parse(raw);
          final text = view.body.plainText;
          final html = view.message.htmlBody?.decodeText().text;
          final things = html == null
              ? const <SchemaThing>[]
              : StructuredData.extract(html);
          return (
            text: text.length > 20000 ? text.substring(0, 20000) : text,
            parcels: ParcelDeliveryInfo.allIn(things),
            orders: OrderInfo.allIn(things),
          );
        } on Object {
          return (
            text: snippet ?? '',
            parcels: const <ParcelDeliveryInfo>[],
            orders: const <OrderInfo>[],
          );
        }
      }()
    else
      (
        text: snippet ?? '',
        parcels: const <ParcelDeliveryInfo>[],
        orders: const <OrderInfo>[],
      ),
];
