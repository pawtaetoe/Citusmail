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

/// What [findTrips] found: every booking the rules found ([hidden] and
/// [learned] ones too, by key), and the emails worth downloading
/// ([toRead]).
typedef TripsFound = ({
  List<Booking> all,
  Set<String> hidden,
  Set<String> learned,
  List<int> toRead,
});

/// The Trips page's findings in [store], reading text and markup off the
/// UI thread. The page and reading in the background both use it, so
/// both want the same emails. [toRead] leaves out [skip].
Future<TripsFound> findTrips(
  MailStore store,
  DateTime now, {
  Set<int> skip = const {},
}) async {
  final hidden = {...TripsModel.hiddenSetting.read(store.settings)};
  final candidates = store.messages.withSubjectWords(
    TripFinder.subjectWords,
    since: now.subtract(TripsModel.lookBack),
  );
  // Message text and markup off the UI thread.
  final read = await _reads.read(store, candidates);
  final emails = <TripEmail>[
    for (final (i, m) in candidates.indexed)
      if (m.from case final from?)
        TripEmail(
          messageId: m.id,
          sender: Domains.registrable(from.domain) ?? from.domain.toLowerCase(),
          senderName: from.displayName,
          subject: m.subject ?? '',
          text: read[i].text,
          at: m.receivedAt,
          reservations: read[i].reservations,
          bulk: m.category == MessageCategory.newsletters,
        ),
  ];
  final all = TripFinder.bookings(emails);
  final messages = {for (final m in candidates) m.id: m};
  final learned = await Corrections(store).vetoed(MailKind.booking, {
    for (final b in all)
      if (!hidden.contains(b.key))
        b.key: bookingSamples(b, (id) => messages[id]),
  });
  return (
    all: all,
    hidden: hidden,
    learned: learned,
    toRead: bookingMailToRead(store, candidates, all, skip: skip),
  );
}

/// Booking mail of [candidates] not understood yet ([all] are the
/// bookings found) and not on the device: its body may say more than its
/// preview. Small ones only, newsletters aside, at most
/// [TripsModel.readMax]; [skip] left out.
List<int> bookingMailToRead(
  MailStore store,
  List<StoredMessage> candidates,
  List<Booking> all, {
  Set<int> skip = const {},
}) {
  final known = {
    for (final b in all)
      for (final r in b.records) r.email.messageId,
  };
  return [
    for (final m in candidates)
      if (m.size <= TripsModel.maxBytes &&
          m.category != MessageCategory.newsletters &&
          !known.contains(m.id) &&
          !skip.contains(m.id) &&
          !MessageReads.downloaded(store, m.id) &&
          TripFinder.looksLikeBooking(m.subject ?? ''))
        m.id,
  ].take(TripsModel.readMax).toList();
}

/// What the classifier reads of [booking]'s emails.
List<MailSample> bookingSamples(
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

/// The Trips page's data: flights, stays, trains, buses, rental cars,
/// tables and tickets found in booking mail, on the device, put together
/// into trips. Downloaded emails are read whole, with the schema.org
/// data in their HTML; the others by their preview. [readEmails]
/// downloads booking emails that are not on the device yet, only when
/// the user asks.
final class TripsModel extends FoundModel<Booking, TripsFound> {
  TripsModel(super.services, {super.now})
    : super(kind: MailKind.booking, hiddenKeys: hiddenSetting);

  static const hiddenSetting = StringListSetting('trips.hidden');

  /// How far back booking mail is looked at (bookings are made months
  /// ahead).
  static const lookBack = Duration(days: 400);

  /// Booking emails downloaded at most, small ones only.
  static const readMax = 40;
  static const maxBytes = 512 * 1024;

  @override
  Future<TripsFound> find(DateTime now, Set<int> skip) =>
      findTrips(store, now, skip: skip);

  @override
  Finds<Booking> findsOf(TripsFound found) => found;

  @override
  String keyOf(Booking item) => item.key;

  @override
  List<MailSample> samplesOf(Booking item) =>
      bookingSamples(item, store.messages.byId);

  final _trips = Expando<List<Trip>>();

  /// Every trip, of bookings not hidden, oldest first.
  List<Trip> get trips => switch (data) {
    final page? => _trips[page] ??= TripFinder.trips(page.listed),
    null => const [],
  };

  DateTime get _today {
    final now = this.now();
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
}

typedef _Read = ({String text, List<ReservationInfo> reservations});

/// What the Trips page has read of each message.
final _reads = MessageReads<_Read>(_read, size: (r) => r.text.length);

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
