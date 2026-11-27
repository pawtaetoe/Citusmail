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

/// What [findAppointments] found: every appointment the rules found
/// ([hidden] and [learned] ones too, by key), and the emails worth
/// downloading ([toRead]).
typedef AppointmentsFound = ({
  List<Appointment> all,
  Set<String> hidden,
  Set<String> learned,
  List<MessageId> toRead,
});

/// The Appointments page's findings in [store], reading text, markup and
/// calendar files off the UI thread. The page, reading in the background
/// and reminders all use it, so all want the same emails. [toRead] leaves
/// out [skip].
Future<AppointmentsFound> findAppointments(
  MailStore store,
  DateTime now, {
  Set<MessageId> skip = const {},
}) async {
  final hidden = {...AppointmentsModel.hiddenSetting.read(store.settings)};
  final candidates = store.messages.withSubjectWords(
    AppointmentFinder.subjectWords,
    since: now.subtract(AppointmentsModel.lookBack),
  );
  // Message text, markup and calendar files off the UI thread.
  final read = await _reads.read(store, candidates);
  final emails = <AppointmentEmail>[
    for (final (i, m) in candidates.indexed)
      if (m.from case final from?)
        AppointmentEmail(
          messageId: m.id,
          sender: Domains.registrable(from.domain) ?? from.domain.toLowerCase(),
          senderName: from.displayName,
          subject: m.subject ?? '',
          text: read[i].text,
          at: m.receivedAt,
          appointments: read[i].appointments,
          reservations: read[i].reservations,
          invite: read[i].invite,
          links: read[i].links,
          bulk: m.category == MessageCategory.newsletters,
        ),
  ];
  final all = AppointmentFinder.find(emails);
  final messages = {for (final m in candidates) m.id: m};
  final learned = await Corrections(store).vetoed(MailKind.appointment, {
    for (final a in all)
      if (!hidden.contains(a.key))
        a.key: appointmentSamples(a, (id) => messages[id]),
  });
  return (
    all: all,
    hidden: hidden,
    learned: learned,
    toRead: appointmentMailToRead(store, candidates, all, skip: skip),
  );
}

/// Reminders for tomorrow's appointments (not cancelled, nor marked or
/// learned "not an appointment"), for a notification the day before.
Future<List<Reminder>> appointmentReminders(
  MailStore store,
  DateTime now,
) async {
  final found = await findAppointments(store, now);
  final left = {...found.hidden, ...found.learned};
  final today = DueDates.dayOf(now);
  return [
    for (final a in found.all)
      if (!a.cancelled && !left.contains(a.key) && a.endsAt.isAfter(now))
        if (localTime(a.start) case final at
            when DateTime.utc(
                  at.year,
                  at.month,
                  at.day,
                ).difference(today).inDays ==
                1)
          Reminder(
            kind: ReminderKind.appointment,
            company: a.sender,
            name: a.title,
            date: DateTime.utc(at.year, at.month, at.day),
            messageId: a.latest.email.messageId,
            at: a.start.hasTime ? at : null,
          ),
  ];
}

/// [t] on this device's clock: an exact moment in the user's time zone,
/// else the clock time as written.
DateTime localTime(PlaceTime t) => t.offset == null
    ? DateTime(
        t.wall.year,
        t.wall.month,
        t.wall.day,
        t.wall.hour,
        t.wall.minute,
      )
    : t.instant.toLocal();

/// Appointment mail of [candidates] not understood yet ([all] are the
/// appointments found) and not on the device: its body may say more
/// than its preview. Small ones only, newsletters aside, at most
/// [AppointmentsModel.readMax]; [skip] left out.
List<MessageId> appointmentMailToRead(
  MailStore store,
  List<StoredMessage> candidates,
  List<Appointment> all, {
  Set<MessageId> skip = const {},
}) {
  final known = {
    for (final a in all)
      for (final r in a.records) r.email.messageId,
  };
  return [
    for (final m in candidates)
      if (m.size <= AppointmentsModel.maxBytes &&
          m.category != MessageCategory.newsletters &&
          !known.contains(m.id) &&
          !skip.contains(m.id) &&
          !MessageReads.downloaded(store, m.id) &&
          AppointmentFinder.looksLikeAppointment(m.subject ?? ''))
        m.id,
  ].take(AppointmentsModel.readMax).toList();
}

/// What the classifier reads of [appointment]'s emails.
List<MailSample> appointmentSamples(
  Appointment appointment,
  StoredMessage? Function(MessageId id) message,
) => [
  for (final r in appointment.records)
    mailSample(
      message(r.email.messageId),
      domain: r.email.sender,
      senderName: r.email.senderName,
      subject: r.email.subject,
      text: r.email.text,
    ),
];

/// The Appointments page's data: a dentist, a salon, a car service, an
/// interview... found in booking mail, on the device. Downloaded emails
/// are read whole, with the schema.org data and calendar file in them;
/// the others by their preview. [readEmails] downloads booking emails
/// that are not on the device yet, only when the user asks.
final class AppointmentsModel
    extends FoundModel<Appointment, AppointmentsFound> {
  AppointmentsModel(super.services, {super.now})
    : super(kind: MailKind.appointment, hiddenKeys: hiddenSetting);

  static const hiddenSetting = StringListSetting('appointments.hidden');

  /// How far back booking mail is looked at (some are booked months
  /// ahead; the past ones of the last year are listed).
  static const lookBack = Duration(days: 400);

  /// Past appointments are listed this long.
  static const pastFor = Duration(days: 365);

  /// Booking emails downloaded at most, small ones only.
  static const readMax = 40;
  static const maxBytes = 512 * 1024;

  @override
  Future<AppointmentsFound> find(DateTime now, Set<MessageId> skip) =>
      findAppointments(store, now, skip: skip);

  @override
  Finds<Appointment> findsOf(AppointmentsFound found) => found;

  @override
  String keyOf(Appointment item) => item.key;

  @override
  List<MailSample> samplesOf(Appointment item) =>
      appointmentSamples(item, store.messages.byId);

  /// Every appointment not hidden, the soonest first.
  List<Appointment> get appointments => listed;

  /// Not over yet, the soonest first (cancelled ones too, shown so).
  List<Appointment> get upcoming => [
    for (final a in appointments)
      if (a.endsAt.isAfter(now())) a,
  ];

  /// Upcoming and not cancelled.
  List<Appointment> get comingUp => [
    for (final a in upcoming)
      if (!a.cancelled) a,
  ];

  /// Over, in the last year, the latest first.
  List<Appointment> get past {
    final now = this.now();
    return [
      for (final a in appointments.reversed)
        if (!a.endsAt.isAfter(now) &&
            now.difference(a.start.instant) <= pastFor)
          a,
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

/// What the Appointments page has read of each message.
final _reads = MessageReads<_Read>(_read, size: (r) => r.text.length);

/// Each message's text (the downloaded body, capped, else its preview),
/// the schema.org data in its raw HTML part (read before the HTML is made
/// safe to show, which drops the scripts holding JSON-LD), its calendar
/// file and its links. Nothing in it is run.
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

/// [invite] as the appointments finder reads it.
@visibleForTesting
AppointmentInvite appointmentInvite(CalendarInvite invite) {
  PlaceTime? time(CalendarTime? t) {
    if (t == null) return null;
    final w = t.wall;
    if (t.allDay) return PlaceTime(w.year, w.month, w.day, hasTime: false);
    return PlaceTime(
      w.year,
      w.month,
      w.day,
      hour: w.hour,
      minute: w.minute,
      // UTC, or a zone whose offset is known: an exact moment. Else the
      // clock time as written.
      offset: t.utc ? Duration.zero : t.offset,
    );
  }

  final organizer = invite.organizer;
  return AppointmentInvite(
    uid: invite.uid,
    sequence: invite.sequence,
    summary: invite.summary,
    location: invite.location,
    description: invite.description,
    start: time(invite.start),
    end: time(invite.end),
    cancelled: invite.cancelled,
    reply: invite.method == CalendarMethod.reply,
    organizerEmail: organizer?.email,
    organizerName: organizer?.name,
    guests: invite.guests.length,
    meetingLink: invite.meetingLink,
  );
}

/// The `https` links in [document], with their words (a link split
/// across bold and plain text is one), at most 60.
@visibleForTesting
List<MailLink> linksIn(RichDocument document) {
  final found = <MailLink>[];
  void readInlines(List<Inline> list) {
    Uri? link;
    final words = StringBuffer();
    void flush() {
      final l = link;
      final label = words.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (l != null && l.scheme == 'https' && label.isNotEmpty) {
        found.add(MailLink(label, l));
      }
      link = null;
      words.clear();
    }

    for (final inline in list) {
      final (Uri? to, String text) = switch (inline) {
        TextRun(:final link, :final text) => (link, text),
        ImageInline(:final link, :final alt) => (link, alt),
        RemoteImageInline(:final link, :final alt) => (link, alt),
        LineBreak() => (null, ''),
      };
      if (to != link) flush();
      link = to;
      if (to != null) words.write(text);
    }
    flush();
  }

  void blocks(List<Block> list) {
    for (final block in list) {
      if (found.length >= 60) return;
      switch (block) {
        case ParagraphBlock(:final inlines) || HeadingBlock(:final inlines):
          readInlines(inlines);
        case QuoteBlock(:final children):
          blocks(children);
        case ListBlock(:final items):
          for (final item in items) {
            blocks(item);
          }
        case TableBlock(:final rows):
          for (final row in rows) {
            for (final cell in row) {
              blocks(cell.blocks);
            }
          }
        case PreformattedBlock() || RuleBlock():
          break;
      }
    }
  }

  blocks(document.blocks);
  return found.take(60).toList();
}
