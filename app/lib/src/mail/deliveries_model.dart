// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../services/app_services.dart';

/// The Deliveries page's data: shipped orders found in shop and carrier
/// mail, on the device. Downloaded emails are read whole, with the
/// schema.org data in their HTML; the others by their preview.
/// [readEmails] downloads shipping emails that are not on the device yet,
/// only when the user asks.
final class DeliveriesModel extends ChangeNotifier {
  DeliveriesModel(this._services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices _services;
  final DateTime Function() _now;

  MailStore get _store => _services.store;

  static const _hiddenKey = 'deliveries.hidden';
  static const _deliveredKey = 'deliveries.delivered';

  /// Return windows the user said were returned, or that they keep.
  static const returnedKey = 'returns.returned';
  static const keptKey = 'returns.kept';

  /// How far back shipping mail is looked at.
  static const lookBack = Duration(days: 365);

  /// Delivered ones stay in "Delivered" this long, then go to "Older".
  static const recent = Duration(days: 30);

  /// Shipping emails downloaded at most, small ones only.
  static const _readMax = 40;
  static const _maxBytes = 256 * 1024;

  bool loading = true;

  /// Every delivery not hidden, newest first.
  List<Delivery> deliveries = const [];

  /// Deliveries the user said are not deliveries (by key).
  Set<String> hidden = const {};
  List<Delivery> hiddenOnes = const [];

  /// Deliveries the user marked delivered (by key).
  Set<String> marked = const {};

  /// Return windows stated in purchase mail (closed ones too), the
  /// soonest deadline first.
  List<ReturnWindow> returns = const [];

  /// Return windows marked "Returned" and "Keeping it" (by key).
  Set<String> returned = const {};
  Set<String> kept = const {};

  /// Shipping emails not on the device yet, newest first.
  List<int> toRead = const [];

  /// While reading emails: how many are done, of how many.
  ({int done, int total})? reading;
  bool _stop = false;

  /// Not delivered yet, the soonest expected first: out for delivery and
  /// ready to collect, then by expected date, then the rest by latest
  /// news.
  List<Delivery> get onTheWay {
    final today = _now();
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
      if (d.arrived && _now().difference(_arrivedAt(d)) <= recent) d,
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
      if (w.daysLeft(_now()) >= 0 &&
          !returned.contains(w.key) &&
          !kept.contains(w.key))
        w,
  ];

  /// Open windows marked "Returned" or "Keeping it", to list again.
  List<ReturnWindow> get doneReturns => [
    for (final w in returns)
      if (w.daysLeft(_now()) >= 0 &&
          (returned.contains(w.key) || kept.contains(w.key)))
        w,
  ];

  /// The return window of the delivery with [key], if its mail states one.
  ReturnWindow? returnFor(String key) =>
      returns.where((w) => w.deliveryKey == key).firstOrNull;

  Set<String> _readSet(String key) => {
    ...?_store.settings.read(key)?.split(',').where((s) => s.isNotEmpty),
  };

  Future<void> load() async {
    hidden = _readSet(_hiddenKey);
    marked = _readSet(_deliveredKey);
    returned = _readSet(returnedKey);
    kept = _readSet(keptKey);
    final mail = await loadDeliveryMail(_store, _now());
    final candidates = mail.messages;
    final all = DeliveryFinder.find(
      mail.shipping,
      now: _now(),
      markedDelivered: marked,
    );
    returns = ReturnWindows.find(mail.emails, deliveries: all);
    deliveries = [
      for (final d in all)
        if (!hidden.contains(d.key)) d,
    ];
    hiddenOnes = [
      for (final d in all)
        if (hidden.contains(d.key)) d,
    ];
    // Where something may be missing: shipping mail not understood yet,
    // and that of deliveries on the way without a tracking number or a
    // date.
    final known = {
      for (final d in all)
        for (final r in d.records) r.email.messageId: d,
    };
    bool worthReading(StoredMessage m) => switch (known[m.id]) {
      null =>
        DeliveryFinder.looksLikeShipping(m.subject ?? '') ||
            ReturnWindows.looksLikeReceipt(m.subject ?? ''),
      final d =>
        !hidden.contains(d.key) &&
            !d.arrived &&
            (d.trackingNumber == null || d.expected == null),
    };
    toRead = [
      for (final m in candidates)
        if (m.size <= _maxBytes &&
            m.category != MessageCategory.newsletters &&
            _store.messages.body(m.id) == null &&
            worthReading(m))
          m.id,
    ].take(_readMax).toList();
    loading = false;
    notifyListeners();
  }

  /// Downloads the emails in [toRead] from the user's own mail server
  /// (they stay unread), then looks again. Stops early on [stopReading].
  Future<void> readEmails() async {
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
        // Gone, too large or offline: read from its preview only.
      }
      reading = (done: ++done, total: ids.length);
      notifyListeners();
    }
    reading = null;
    await load();
  }

  void stopReading() => _stop = true;

  /// "Not a delivery": hidden from the list (undoable).
  void hide(String key) => _write(_hiddenKey, {...hidden, key});

  void unhide(String key) => _write(_hiddenKey, {...hidden}..remove(key));

  /// "Mark as delivered", for one stuck on the way (undoable).
  void markDelivered(String key) => _write(_deliveredKey, {...marked, key});

  void unmarkDelivered(String key) =>
      _write(_deliveredKey, {...marked}..remove(key));

  /// "Returned" and "Keeping it": no longer listed under "Can still be
  /// returned" (undoable).
  void markReturned(String key) => _write(returnedKey, {...returned, key});

  void markKept(String key) => _write(keptKey, {...kept, key});

  /// Listed again as one that can still be returned.
  void unmarkReturn(String key) {
    _store.settings.write(returnedKey, ({...returned}..remove(key)).join(','));
    _write(keptKey, {...kept}..remove(key));
  }

  void _write(String settingsKey, Set<String> keys) {
    _store.settings.write(settingsKey, keys.join(','));
    unawaited(load());
  }

  StoredMessage? message(int id) => _store.messages.byId(id);
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
  final read = await compute(_read, [
    for (final m in candidates) (store.messages.body(m.id), m.snippet),
  ]);
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
  Set<String> read(String key) => {
    ...?store.settings.read(key)?.split(',').where((s) => s.isNotEmpty),
  };
  final done = {
    ...read(DeliveriesModel.returnedKey),
    ...read(DeliveriesModel.keptKey),
  };
  final mail = await loadDeliveryMail(store, now);
  final deliveries = DeliveryFinder.find(
    mail.shipping,
    now: now,
    markedDelivered: read(DeliveriesModel._deliveredKey),
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
