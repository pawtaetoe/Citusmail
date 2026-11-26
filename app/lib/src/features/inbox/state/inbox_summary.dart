// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_extract/mail_extract.dart' show DeliveryStatus;
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../services/app_services.dart';
import '../../../services/reminders.dart' show ReminderState;
import '../../found/state/appointments_model.dart';
import '../../found/state/deliveries_model.dart';
import '../../found/state/subscriptions_model.dart';
import '../../found/state/trips_model.dart';
import 'message_list_model.dart';
import 'store_changes.dart';

/// One piece of the summary line at the top of the inbox.
sealed class SummaryPiece {
  const SummaryPiece();
}

/// Unread mail in the inbox; [first] is the first one shown, if loaded.
final class NewMailPiece extends SummaryPiece {
  const NewMailPiece(this.count, this.first);

  final int count;
  final StoredMessage? first;
}

/// The newest verification code still worth using. The line names its
/// sender only; the code itself is copied, never shown there.
final class CodePiece extends SummaryPiece {
  const CodePiece(this.message);

  final StoredMessage message;

  String get code => message.shownCode ?? '';
}

/// Parcels arriving today.
final class DeliveriesPiece extends SummaryPiece {
  const DeliveriesPiece(this.deliveries);

  final List<Delivery> deliveries;
}

/// The next appointment today.
final class AppointmentPiece extends SummaryPiece {
  const AppointmentPiece(this.appointment);

  final Appointment appointment;
}

/// The next booking today (a flight, a hotel, a table).
final class BookingPiece extends SummaryPiece {
  const BookingPiece(this.booking);

  final Booking booking;
}

/// A bill, a free trial or a renewal due today or tomorrow.
final class BillPiece extends SummaryPiece {
  const BillPiece(this.reminder);

  final Reminder reminder;
}

/// What the "Found in your mail" pages know of today, read with the same
/// finders (and the same caches) as the pages: deliveries arriving,
/// appointments and bookings, and bills, free trials and renewals due
/// today or tomorrow. Those the user hid, marked or dismissed are left
/// out, as on the pages.
final class FoundToday {
  const FoundToday({
    this.deliveries = const [],
    this.appointments = const [],
    this.bookings = const [],
    this.bills = const [],
  });

  static const none = FoundToday();

  final List<Delivery> deliveries;
  final List<Appointment> appointments;
  final List<Booking> bookings;
  final List<Reminder> bills;
}

/// [now]'s calendar day on this device.
DateTime _day(DateTime now) {
  final local = now.toLocal();
  return DateTime(local.year, local.month, local.day);
}

bool _sameDay(DateTime a, DateTime b) => _day(a) == _day(b);

/// Today's findings in [store], from the mail on the device; nothing is
/// downloaded.
Future<FoundToday> findToday(
  MailStore store,
  DateTime now, {
  required bool monthlyRenewals,
}) async {
  final deliveries = await findDeliveries(store, now);
  final appointments = await findAppointments(store, now);
  final trips = await findTrips(store, now);
  final subscriptions = await findSubscriptions(
    store,
    now,
    monthlyRenewals: monthlyRenewals,
  );
  final dismissed = ReminderState(store).dismissed;
  bool left(Set<String> a, Set<String> b, String key) =>
      a.contains(key) || b.contains(key);
  return FoundToday(
    deliveries: [
      for (final d in deliveries.all)
        if (!left(deliveries.hidden, deliveries.learned, d.key) &&
            !d.arrived &&
            now.difference(d.lastUpdate) <= DeliveriesModel.recent &&
            (d.status == DeliveryStatus.outForDelivery ||
                (d.expected != null && _sameDay(d.expected!, now))))
          d,
    ],
    appointments: [
      for (final a in appointments.all)
        if (!left(appointments.hidden, appointments.learned, a.key) &&
            !a.cancelled &&
            _sameDay(localTime(a.start), now))
          a,
    ],
    bookings: [
      for (final b in trips.all)
        if (!left(trips.hidden, trips.learned, b.key) &&
            !b.cancelled &&
            _sameDay(b.start.day, now))
          b,
    ],
    bills: [
      for (final r in subscriptions.reminders)
        if (r.kind != ReminderKind.returnBy &&
            r.kind != ReminderKind.appointment &&
            !dismissed.contains(r.key) &&
            r.daysFrom(now) >= 0 &&
            r.daysFrom(now) <= 1)
          r,
    ],
  );
}

/// The summary line at the top of the inbox, e.g. "3 new · Code from
/// Northwind · Parcel arriving today · Dentist at 3:00 PM": built on the
/// device from what the app already has. Nothing leaves the device.
///
/// New mail and the latest code come from the list as loaded (no query
/// of their own), so they follow it at once as mail arrives or is read.
/// Today's deliveries, appointments, trips and bills come from the
/// pages' finders, whose reads are kept per message: they are looked at
/// again only while the line is watched ([watch]), after something in
/// the store changed, at most every [minGap], and not at all with
/// "Read receipts and bookings automatically" off. Bills follow the
/// "Bill and trial reminders" setting.
final class InboxSummary extends ChangeNotifier {
  InboxSummary(this._services, this._list) {
    _list.addListener(update);
    _services.settings.syncedChanges.addListener(update);
    pieces = _compute();
  }

  final AppServices _services;
  final MessageListModel _list;

  /// At most this many pieces.
  static const maxPieces = 4;

  /// A code this recent is still worth copying.
  static const codeFresh = Duration(minutes: 15);

  /// Today's findings are read again at most this often.
  static const minGap = Duration(minutes: 1);

  /// How long a change waits for more before the findings are read.
  static const delay = Duration(seconds: 2);

  /// The clock (replaced in tests).
  static DateTime Function() clock = DateTime.now;

  /// Reads today's findings (tests replace it).
  @visibleForTesting
  static Future<FoundToday> Function(
    MailStore store,
    DateTime now, {
    required bool monthlyRenewals,
  })
  find = findToday;

  /// What the line shows, in order; empty for no line.
  List<SummaryPiece> pieces = const [];

  MailStore get _store => _services.store;

  int _watchers = 0;
  Timer? _tick;
  Timer? _load;
  bool _loading = false;
  bool _disposed = false;

  FoundToday? _found;
  DateTime? _foundDay;
  DateTime? _lastLoad;
  (int, int)? _foundStamp;
  late final _changes = StoreChanges(_store);

  /// The line is on screen: today's findings are kept up to date, and
  /// pieces go when their time is over. Pair with [unwatch].
  void watch() {
    if (_watchers++ == 0) update();
  }

  void unwatch() {
    if (--_watchers > 0) return;
    _watchers = 0;
    _tick?.cancel();
    _tick = null;
    _load?.cancel();
    _load = null;
  }

  /// Builds the pieces again (the list changed, a setting changed).
  void update() {
    if (_disposed) return;
    pieces = _compute();
    notifyListeners();
    if (_watchers > 0) {
      _scheduleTick();
      _maybeLoad();
    }
  }

  List<SummaryPiece> _compute() {
    final settings = _services.settings;
    if (!settings.summaryLine || !_list.showsSections) return const [];
    final now = clock();
    final loaded = [
      ..._list.newSinceAway.messages,
      for (final s in _list.sections) ...s.messages,
    ];
    final unread =
        _list.newSinceAway.unread +
        _list.sections.fold<int>(0, (sum, s) => sum + s.count.unread);
    StoredMessage? code;
    for (final m in loaded) {
      if (m.shownCode == null || !_fresh(m, now)) continue;
      if (code == null || m.receivedAt.isAfter(code.receivedAt)) code = m;
    }
    final found = settings.autoRead && _foundDay == _day(now)
        ? _found ?? FoundToday.none
        : FoundToday.none;
    return compose(
      unread: unread,
      firstUnread: [
        ..._list.visible,
        ...loaded,
      ].where((m) => !m.flags.seen).firstOrNull,
      code: code,
      found: found,
      bills: settings.reminders,
      now: now,
    );
  }

  static bool _fresh(StoredMessage m, DateTime now) =>
      now.difference(m.receivedAt) <= codeFresh;

  /// The pieces for what is true at [now], in order, at most [maxPieces]:
  /// new mail, the latest code, deliveries arriving today, the next
  /// appointment or booking today, a bill due today or tomorrow (with
  /// [bills]).
  static List<SummaryPiece> compose({
    required int unread,
    StoredMessage? firstUnread,
    StoredMessage? code,
    FoundToday found = FoundToday.none,
    bool bills = true,
    required DateTime now,
  }) {
    final next = _next(found, now);
    final bill = bills
        ? ([
            ...found.bills,
          ]..sort((a, b) => a.date.compareTo(b.date))).firstOrNull
        : null;
    return [
      if (unread > 0) NewMailPiece(unread, firstUnread),
      if (code != null && code.shownCode != null) CodePiece(code),
      if (found.deliveries.isNotEmpty) DeliveriesPiece(found.deliveries),
      ?next,
      if (bill != null) BillPiece(bill),
    ].take(maxPieces).toList();
  }

  /// The next appointment or booking today not over at [now]: those at a
  /// time first, by time, then those for the whole day.
  static SummaryPiece? _next(FoundToday found, DateTime now) {
    final options = <(bool, DateTime, SummaryPiece)>[
      for (final a in found.appointments)
        if (a.endsAt.isAfter(now))
          (a.start.hasTime, localTime(a.start), AppointmentPiece(a)),
      for (final b in found.bookings)
        if (b.endsAt.isAfter(now))
          (b.start.hasTime, b.start.instant, BookingPiece(b)),
    ];
    options.sort((x, y) {
      if (x.$1 != y.$1) return x.$1 ? -1 : 1;
      return x.$2.compareTo(y.$2);
    });
    return options.firstOrNull?.$3;
  }

  /// A tick when a piece's time is over: the code gets old, the
  /// appointment ends, the day ends.
  void _scheduleTick() {
    _tick?.cancel();
    final now = clock();
    final local = now.toLocal();
    final times = <DateTime>[
      DateTime(local.year, local.month, local.day + 1, 0, 0, 1),
      for (final p in pieces)
        ?switch (p) {
          CodePiece(:final message) => message.receivedAt.add(codeFresh),
          AppointmentPiece(:final appointment) => appointment.endsAt,
          BookingPiece(:final booking) => booking.endsAt,
          _ => null,
        },
    ];
    final next = times.reduce((a, b) => a.isBefore(b) ? a : b);
    var wait = next.difference(now) + const Duration(seconds: 1);
    if (wait.isNegative) wait = const Duration(seconds: 1);
    // Timers may stop while the device sleeps: an update at least hourly.
    if (wait > const Duration(hours: 1)) wait = const Duration(hours: 1);
    _tick = Timer(wait, update);
  }

  /// Reads today's findings soon if they are missing, of another day, or
  /// something changed in the store since.
  void _maybeLoad() {
    final settings = _services.settings;
    if (!settings.summaryLine || !settings.autoRead || !_list.showsSections) {
      return;
    }
    if (_loading || _load != null) return;
    final now = clock();
    final stale =
        _found == null ||
        _foundDay != _day(now) ||
        _changes.stamp != _foundStamp;
    if (!stale) return;
    var wait = delay;
    if (_lastLoad case final last?) {
      final gap = last.add(minGap).difference(now);
      if (gap > wait) wait = gap;
    }
    _load = Timer(wait, () {
      _load = null;
      unawaited(_read());
    });
  }

  Future<void> _read() async {
    if (_disposed || _watchers == 0) return;
    _loading = true;
    final now = clock();
    try {
      final found = await find(
        _store,
        now,
        monthlyRenewals: _services.settings.monthlyRenewals,
      );
      if (_disposed) return;
      _found = found;
      _foundDay = _day(now);
    } on Object catch (e) {
      debugPrint('summary line: ${e.runtimeType}');
    } finally {
      _loading = false;
      _lastLoad = clock();
    }
    if (_disposed) return;
    // What the reading itself wrote doesn't count as a change.
    _foundStamp = _changes.stamp;
    update();
  }

  @override
  void dispose() {
    _disposed = true;
    unwatch();
    _list.removeListener(update);
    _services.settings.syncedChanges.removeListener(update);
    super.dispose();
  }
}
