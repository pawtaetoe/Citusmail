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
import 'corrections.dart';

/// The Trips page's data: flights, stays, trains, buses, rental cars,
/// tables and tickets found in booking mail, on the device, put together
/// into trips. Downloaded emails are read whole, with the schema.org
/// data in their HTML; the others by their preview. [readEmails]
/// downloads booking emails that are not on the device yet, only when
/// the user asks.
final class TripsModel extends ChangeNotifier {
  TripsModel(this._services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices _services;
  final DateTime Function() _now;

  MailStore get _store => _services.store;

  static const _hiddenKey = 'trips.hidden';

  /// How far back booking mail is looked at (bookings are made months
  /// ahead).
  static const lookBack = Duration(days: 400);

  /// Booking emails downloaded at most, small ones only.
  static const _readMax = 40;
  static const _maxBytes = 512 * 1024;

  bool loading = true;

  /// Every trip, of bookings not hidden, oldest first.
  List<Trip> trips = const [];

  /// Bookings the user said are not bookings (by key).
  Set<String> hidden = const {};

  /// Bookings left out because they look like ones the user said are not
  /// bookings ("Learn from my corrections"; by key).
  Set<String> learned = const {};

  /// Those of [hidden] and [learned].
  List<Booking> hiddenOnes = const [];

  /// Everything the rules found.
  List<Booking> _all = const [];

  late final _corrections = Corrections(_store);

  /// Booking emails not on the device yet, newest first.
  List<int> toRead = const [];

  /// While reading emails: how many are done, of how many.
  ({int done, int total})? reading;
  bool _stop = false;

  DateTime get _today {
    final now = _now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Trips not over yet, the soonest first.
  List<Trip> get upcoming => [
    for (final t in trips)
      if (!t.endsAt.isBefore(_today)) t,
  ];

  /// Trips that are over, the latest first.
  List<Trip> get past => [
    for (final t in trips.reversed)
      if (t.endsAt.isBefore(_today)) t,
  ];

  Future<void> load() async {
    hidden = {
      ...?_store.settings
          .read(_hiddenKey)
          ?.split(',')
          .where((s) => s.isNotEmpty),
    };
    final candidates = _store.messages.withSubjectWords(
      TripFinder.subjectWords,
      since: _now().subtract(lookBack),
    );
    // Message text and markup off the UI thread.
    final read = await compute(_read, [
      for (final m in candidates) (_store.messages.body(m.id), m.snippet),
    ]);
    final emails = <TripEmail>[
      for (final (i, m) in candidates.indexed)
        if (m.from case final from?)
          TripEmail(
            messageId: m.id,
            sender:
                Domains.registrable(from.domain) ?? from.domain.toLowerCase(),
            senderName: from.displayName,
            subject: m.subject ?? '',
            text: read[i].text,
            at: m.receivedAt,
            reservations: read[i].reservations,
            bulk: m.category == MessageCategory.newsletters,
          ),
    ];
    final all = TripFinder.bookings(emails);
    _all = all;
    final messages = {for (final m in candidates) m.id: m};
    learned = await _corrections.vetoed(MailKind.booking, {
      for (final b in all)
        if (!hidden.contains(b.key)) b.key: _samples(b, (id) => messages[id]),
    });
    final left = {...hidden, ...learned};
    trips = TripFinder.trips([
      for (final b in all)
        if (!left.contains(b.key)) b,
    ]);
    hiddenOnes = [
      for (final b in all)
        if (left.contains(b.key)) b,
    ];
    // Booking mail not understood yet: its body may say more than its
    // preview.
    final known = {
      for (final b in all)
        for (final r in b.records) r.email.messageId,
    };
    toRead = [
      for (final m in candidates)
        if (m.size <= _maxBytes &&
            m.category != MessageCategory.newsletters &&
            !known.contains(m.id) &&
            _store.messages.body(m.id) == null &&
            TripFinder.looksLikeBooking(m.subject ?? ''))
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

  /// "Not a booking": hidden from the trips (undoable), and learned
  /// from.
  void hide(String key) {
    if (_found(key) case final b?) {
      _corrections.rejected(
        MailKind.booking,
        _samples(b, _store.messages.byId),
      );
    }
    _write({...hidden, key});
  }

  /// Undo, or "List again": listed again (and never left out by
  /// learning again).
  void unhide(String key) {
    final b = _found(key);
    final samples = b == null
        ? const <MailSample>[]
        : _samples(b, _store.messages.byId);
    if (hidden.contains(key)) {
      _corrections.rejected(MailKind.booking, samples, undo: true);
      _write({...hidden}..remove(key));
    } else if (learned.contains(key)) {
      _corrections.kept(MailKind.booking, key, samples);
      unawaited(load());
    }
  }

  /// [booking]'s page was opened: a weak sign that it is one.
  void opened(Booking booking) => _corrections.opened(
    MailKind.booking,
    booking.key,
    _samples(booking, _store.messages.byId),
  );

  Booking? _found(String key) => _all.where((b) => b.key == key).firstOrNull;

  /// What the classifier reads of [booking]'s emails.
  static List<MailSample> _samples(
    Booking booking,
    StoredMessage? Function(int id) message,
  ) => [
    for (final r in booking.records)
      mailSample(
        message(r.email.messageId),
        domain: r.email.sender,
        senderName: r.email.senderName,
        subject: r.email.subject,
        text: r.email.text,
      ),
  ];

  void _write(Set<String> keys) {
    _store.settings.write(_hiddenKey, keys.join(','));
    unawaited(load());
  }

  StoredMessage? message(int id) => _store.messages.byId(id);
}

typedef _Read = ({String text, List<ReservationInfo> reservations});

/// Each message's text (the downloaded body, capped, else its preview)
/// and the reservations in its raw HTML part, read before the HTML is
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
          return (
            text: text.length > 20000 ? text.substring(0, 20000) : text,
            reservations: html == null
                ? const <ReservationInfo>[]
                : ReservationInfo.allIn(StructuredData.extract(html)),
          );
        } on Object {
          return (text: snippet ?? '', reservations: const <ReservationInfo>[]);
        }
      }()
    else
      (text: snippet ?? '', reservations: const <ReservationInfo>[]),
];
