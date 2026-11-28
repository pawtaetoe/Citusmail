// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/state/page_model.dart';
import '../../../services/app_services.dart';
import '../../../services/store_reader.dart';
import '../../found/state/appointments_model.dart';
import '../../found/state/events_model.dart';
import '../../found/state/found_model.dart' show Finds;
import '../../found/state/subscriptions_model.dart';
import '../../found/state/trips_model.dart';

/// Which page of "Found in your mail" an item on the calendar comes from
/// ([money]: Subscriptions' renewals, bills due and free trials ending).
enum CalendarSource { trip, appointment, event, money }

/// One dated thing on the calendar: a flight, a stay's check-in or
/// check-out, an appointment, an event or a meeting.
final class CalendarItem {
  const CalendarItem({
    required this.key,
    required this.source,
    required this.item,
    required this.start,
    required this.day,
    required this.endsAt,
    required this.messageId,
    this.end,
    this.checkOut = false,
  });

  /// Stable across loads: the item's own key, and for a stay's
  /// check-out, `:out` after it.
  final String key;
  final CalendarSource source;

  /// What it is: a [Booking], an [Appointment], an [Event] or a
  /// [Reminder] (a renewal, a bill due, a free trial ending).
  final Object item;

  /// When it starts, as its page gives it.
  final PlaceTime start;
  final PlaceTime? end;

  /// The day it shows under: on this device's clock for an exact moment
  /// (appointments, events), else the place's (a flight's, a hotel's),
  /// as each page shows it.
  final DateTime day;

  /// When it is over.
  final DateTime endsAt;

  /// The newest email about it, to open.
  final MessageId messageId;

  /// A stay's last day: the check-out, not the check-in.
  final bool checkOut;

  bool get cancelled => switch (item) {
    final Booking b => b.cancelled,
    final Appointment a => a.cancelled,
    final Event e => e.cancelled,
    _ => false,
  };

  @override
  String toString() => 'CalendarItem($key)';
}

/// A day of the calendar and what is on it, in order.
typedef CalendarDay = ({DateTime day, List<CalendarItem> items});

/// Everything dated that the "Found in your mail" pages found, as listed
/// there (not what the user marked "Not a …"): each flight, train, bus,
/// rental car, table and stay (its check-in and its check-out), every
/// appointment, every event, meeting and interview, and each active
/// subscription's next charge, bill due and free trial ending. Soonest
/// first.
Future<List<CalendarItem>> findCalendar(MailStore store, DateTime now) async {
  final trips = await findTrips(store, now);
  final appointments = await findAppointments(store, now);
  final events = await findEvents(store, now);
  // Every renewal, monthly ones too: the calendar is not a notification.
  final money = await findSubscriptions(store, now, monthlyRenewals: true);
  final moneyLeft = {...money.hidden, ...money.learned};
  bool listed(String key, Finds<Object?> found) =>
      !found.hidden.contains(key) && !found.learned.contains(key);
  DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
  final items = <CalendarItem>[
    for (final b in trips.all)
      if (listed(b.key, trips)) ...[
        CalendarItem(
          key: b.key,
          source: CalendarSource.trip,
          item: b,
          start: b.start,
          end: b.end,
          day: b.start.day,
          endsAt: b.kind == ReservationKind.stay ? b.start.instant : b.endsAt,
          messageId: b.records.last.email.messageId,
        ),
        if (b.kind == ReservationKind.stay)
          if (b.end case final out? when out.day.isAfter(b.start.day))
            CalendarItem(
              key: '${b.key}:out',
              source: CalendarSource.trip,
              item: b,
              start: out,
              day: out.day,
              endsAt: b.endsAt,
              messageId: b.records.last.email.messageId,
              checkOut: true,
            ),
      ],
    for (final a in appointments.all)
      if (listed(a.key, appointments))
        CalendarItem(
          key: a.key,
          source: CalendarSource.appointment,
          item: a,
          start: a.start,
          end: a.end,
          day: dayOf(localTime(a.start)),
          endsAt: a.endsAt,
          messageId: a.latest.email.messageId,
        ),
    for (final e in events.all)
      if (listed(e.key, events))
        CalendarItem(
          key: e.key,
          source: CalendarSource.event,
          item: e,
          start: e.start,
          end: e.end,
          day: dayOf(localTime(e.start)),
          endsAt: e.endsAt,
          messageId: e.latest.email.messageId,
        ),
    // Bills due and free trials ending, as Subscriptions lists them.
    for (final r in money.reminders)
      if (r.kind == ReminderKind.billDue || r.kind == ReminderKind.trialEnds)
        if (!moneyLeft.contains(r.company)) _moneyItem(r),
    // The next charge of each active subscription, however far.
    for (final s in money.all)
      if (s.nextCharge case final next?
          when s.status == SubscriptionStatus.active &&
              !s.variable &&
              !moneyLeft.contains(s.company))
        _moneyItem(
          Reminder(
            kind: ReminderKind.renewal,
            company: s.company,
            name: s.name,
            date: DateTime.utc(next.year, next.month, next.day),
            messageId:
                (s.records
                            .where((r) => r.event == SubscriptionEvent.charge)
                            .firstOrNull ??
                        s.records.first)
                    .email
                    .messageId,
            amount: s.amount,
            cadence: s.cadence,
          ),
        ),
  ];
  items.sort((a, b) {
    final byDay = a.day.compareTo(b.day);
    if (byDay != 0) return byDay;
    // All day first, then by time.
    if (a.start.hasTime != b.start.hasTime) return a.start.hasTime ? 1 : -1;
    return a.start.compareTo(b.start);
  });
  return items;
}

/// [r] on its day, all day.
CalendarItem _moneyItem(Reminder r) {
  final day = DateTime(r.date.year, r.date.month, r.date.day);
  return CalendarItem(
    key: 'money:${r.kind.name}:${r.company}',
    source: CalendarSource.money,
    item: r,
    start: PlaceTime(day.year, day.month, day.day, hasTime: false),
    day: day,
    endsAt: day.add(const Duration(days: 1)),
    messageId: r.messageId,
  );
}

/// [findCalendar] as a [StoreTask], off the UI isolate.
StoreTask<List<CalendarItem>> _calendarTask(DateTime now) =>
    (store) => findCalendar(store, now);

/// The calendar's data: [findCalendar], split into what is coming up and
/// what is over, by day.
final class CalendarModel extends PageModel<List<CalendarItem>> {
  CalendarModel(this.services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices services;
  final DateTime Function() _now;

  /// Past items are listed this long.
  static const pastFor = Duration(days: 365);

  DateTime now() => _now();

  DateTime get today {
    final n = now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  Future<List<CalendarItem>> fetch() =>
      services.reads.run(_calendarTask(now()));

  /// Every item, soonest first.
  List<CalendarItem> get items => data ?? const [];

  /// Not over yet, by day, the soonest first; what started before today
  /// and is still on shows under today.
  List<CalendarDay> get upcoming {
    final now = this.now();
    final today = this.today;
    return _byDay([
      for (final i in items)
        if (i.endsAt.isAfter(now)) i,
    ], floor: today);
  }

  /// Over, in the last year, by day, the latest first.
  List<CalendarDay> get past {
    final now = this.now();
    final over = [
      for (final i in items)
        if (!i.endsAt.isAfter(now) && now.difference(i.endsAt) <= pastFor) i,
    ];
    return _byDay(over).reversed.toList();
  }

  /// The days of [month] (any day in it) that have something on.
  Set<DateTime> busyDays(DateTime month) => {
    for (final i in items)
      if (i.day.year == month.year && i.day.month == month.month) i.day,
  };

  /// What is on [day], in order.
  List<CalendarItem> on(DateTime day) => [
    for (final i in items)
      if (i.day == DateTime(day.year, day.month, day.day)) i,
  ];

  static List<CalendarDay> _byDay(List<CalendarItem> items, {DateTime? floor}) {
    final days = <DateTime, List<CalendarItem>>{};
    for (final i in items) {
      final day = floor != null && i.day.isBefore(floor) ? floor : i.day;
      days.putIfAbsent(day, () => []).add(i);
    }
    final keys = days.keys.toList()..sort();
    return [for (final d in keys) (day: d, items: days[d]!)];
  }
}
