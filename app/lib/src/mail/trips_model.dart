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
  List<Booking> hiddenOnes = const [];

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
    trips = TripFinder.trips([
      for (final b in all)
        if (!hidden.contains(b.key)) b,
    ]);
    hiddenOnes = [
      for (final b in all)
        if (hidden.contains(b.key)) b,
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

  /// "Not a booking": hidden from the trips (undoable).
  void hide(String key) => _write({...hidden, key});

  void unhide(String key) => _write({...hidden}..remove(key));

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
