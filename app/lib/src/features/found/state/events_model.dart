// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../../../services/store_reader.dart';
import '../../inbox/state/corrections.dart';
import '../../inbox/state/message_reads.dart';
import 'appointments_model.dart' show appointmentInvite, linksIn;
import 'found_model.dart';

/// What [findEvents] found: every event the rules found ([hidden] and
/// [learned] ones too, by key), and the emails worth downloading
/// ([toRead]).
typedef EventsFound = ({
  List<Event> all,
  Set<String> hidden,
  Set<String> learned,
  List<MessageId> toRead,
});

/// The Events page's findings in [store], reading text, markup and
/// calendar files off the UI thread. The page and the calendar both use
/// it. [toRead] leaves out [skip].
Future<EventsFound> findEvents(
  MailStore store,
  DateTime now, {
  Set<MessageId> skip = const {},
}) async {
  final hidden = {...EventsModel.hiddenSetting.read(store.settings)};
  final candidates = store.messages.withSubjectWords(
    EventFinder.subjectWords,
    since: now.subtract(EventsModel.lookBack),
  );
  // Message text, markup and calendar files off the UI thread.
  final read = await _reads.read(store, candidates);
  final emails = <EventEmail>[
    for (final (i, m) in candidates.indexed)
      if (m.from case final from?)
        EventEmail(
          messageId: m.id,
          sender: Domains.registrable(from.domain) ?? from.domain.toLowerCase(),
          senderName: from.displayName,
          subject: m.subject ?? '',
          text: read[i].text,
          at: m.receivedAt,
          reservations: read[i].reservations,
          appointments: read[i].appointments,
          invite: read[i].invite,
          links: read[i].links,
          bulk: m.category == MessageCategory.newsletters,
        ),
  ];
  final all = EventFinder.find(emails);
  final messages = {for (final m in candidates) m.id: m};
  final learned = await Corrections(store).vetoed(MailKind.booking, {
    for (final e in all)
      if (!hidden.contains(e.key)) e.key: eventSamples(e, (id) => messages[id]),
  });
  return (
    all: all,
    hidden: hidden,
    learned: learned,
    toRead: eventMailToRead(store, candidates, all, skip: skip),
  );
}

/// Event mail of [candidates] not understood yet ([all] are the events
/// found) and not on the device: its body may say more than its preview.
/// Small ones only, newsletters aside, at most [EventsModel.readMax];
/// [skip] left out.
List<MessageId> eventMailToRead(
  MailStore store,
  List<StoredMessage> candidates,
  List<Event> all, {
  Set<MessageId> skip = const {},
}) {
  final known = {
    for (final e in all)
      for (final r in e.records) r.email.messageId,
  };
  return [
    for (final m in candidates)
      if (m.size <= EventsModel.maxBytes &&
          m.category != MessageCategory.newsletters &&
          !known.contains(m.id) &&
          !skip.contains(m.id) &&
          !MessageReads.downloaded(store, m.id) &&
          EventFinder.looksLikeEvent(m.subject ?? '', preview: m.snippet ?? ''))
        m.id,
  ].take(EventsModel.readMax).toList();
}

/// What the classifier reads of [event]'s emails.
List<MailSample> eventSamples(
  Event event,
  StoredMessage? Function(MessageId id) message,
) => [
  for (final r in event.records)
    mailSample(
      message(r.email.messageId),
      domain: r.email.sender,
      senderName: r.email.senderName,
      subject: r.email.subject,
      text: r.email.text,
    ),
];

/// [findEvents] as a [StoreTask], off the UI isolate.
StoreTask<EventsFound> _eventsTask(DateTime now, Set<MessageId> skip) =>
    (store) => findEvents(store, now, skip: skip);

/// The Events page's data: tours, concerts, shows, films, matches,
/// exhibitions, workshops, meetings and interviews found in ticket and
/// booking mail and in calendar invitations, on the device. Downloaded
/// emails are read whole, with the schema.org data and calendar file in
/// them; the others by their preview. [readEmails] downloads ticket
/// emails that are not on the device yet, only when the user asks.
///
/// "Not an event" is learned as "not a booking": tickets were bookings
/// (on Trips) before they had a page of their own, and the mail model
/// knows them as such.
final class EventsModel extends FoundModel<Event, EventsFound> {
  EventsModel(super.services, {super.now})
    : super(kind: MailKind.booking, hiddenKeys: hiddenSetting);

  static const hiddenSetting = StringListSetting('events.hidden');

  /// How far back ticket mail is looked at (tickets are bought months
  /// ahead; the past ones of the last year are listed).
  static const lookBack = Duration(days: 400);

  /// Past events are listed this long.
  static const pastFor = Duration(days: 365);

  /// Ticket emails downloaded at most, small ones only.
  static const readMax = 40;
  static const maxBytes = 512 * 1024;

  @override
  Future<EventsFound> find(DateTime now, Set<MessageId> skip) =>
      services.reads.run(_eventsTask(now, skip));

  @override
  Finds<Event> findsOf(EventsFound found) => found;

  @override
  String keyOf(Event item) => item.key;

  @override
  List<MailSample> samplesOf(Event item) =>
      eventSamples(item, store.messages.byId);

  /// Every event not hidden, the soonest first.
  List<Event> get events => listed;

  /// Not over yet, the soonest first (cancelled ones too, shown so).
  List<Event> get upcoming => [
    for (final e in events)
      if (e.endsAt.isAfter(now())) e,
  ];

  /// Upcoming and not cancelled.
  List<Event> get comingUp => [
    for (final e in upcoming)
      if (!e.cancelled) e,
  ];

  /// Over, in the last year, the latest first.
  List<Event> get past {
    final now = this.now();
    return [
      for (final e in events.reversed)
        if (!e.endsAt.isAfter(now) &&
            now.difference(e.start.instant) <= pastFor)
          e,
    ];
  }
}

typedef _Read = ({
  String text,
  List<AppointmentInfo> appointments,
  List<ReservationInfo> reservations,
  AppointmentInvite? invite,
  List<MailLink> links,
});

/// What the Events page has read of each message.
final _reads = MessageReads<_Read>(_read, size: (r) => r.text.length);

/// Each message's text (the downloaded body, capped, else its preview),
/// the schema.org data in its raw HTML part, its calendar file and its
/// links. Nothing in it is run.
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
            appointments: AppointmentInfo.allIn(things),
            reservations: ReservationInfo.allIn(things),
            invite: switch (view.invite) {
              final i? => appointmentInvite(i),
              null => null,
            },
            links: linksIn(view.body),
          );
        } on Object {
          return _preview(snippet);
        }
      }()
    else
      _preview(snippet),
];

_Read _preview(String? snippet) => (
  text: snippet ?? '',
  appointments: const <AppointmentInfo>[],
  reservations: const <ReservationInfo>[],
  invite: null,
  links: const <MailLink>[],
);
