// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_view/mail_view.dart';

import '../../../core/state/load_state.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/citusmail_theme.dart';
import '../../../core/widgets/badge.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/skeleton_rows.dart';
import '../../found/ui/add_to_calendar.dart';
import '../../found/ui/appointment_text.dart';
import '../../found/ui/booking_text.dart';
import '../../found/ui/event_text.dart';
import '../../inbox/state/mail_controller.dart';
import '../../reader/ui/calendar_files.dart';
import '../../reader/ui/email_page.dart';
import '../state/calendar_model.dart';

/// The calendar on a page of its own (wide screens, "All features").
final class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Now (tests).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'Calendar',
    help: (
      tooltip: 'What is on the calendar?',
      onPressed: () => CalendarView.explain(context),
    ),
    body: SafeArea(
      top: false,
      child: CalendarView(controller: controller, now: now),
    ),
  );
}

/// Everything dated found in your mail, by day: trips (each flight,
/// train, stay), appointments, and events, meetings and interviews. What
/// is coming up first, the past on request, and a month above with a dot
/// on each busy day (tap one to see only it). Each item opens the email
/// it came from, and goes to the user's own calendar app on request.
final class CalendarView extends StatefulWidget {
  const CalendarView({super.key, required this.controller, this.now});

  final MailController controller;

  /// Now (tests).
  final DateTime Function()? now;

  /// What the calendar shows, and where it comes from.
  static Future<void> explain(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('What is on the calendar?'),
      content: const SingleChildScrollView(
        child: Text(
          'Everything with a date that Citusmail found in your mail, on this '
          'device: flights, trains and hotel stays from Trips, appointments, '
          'and tickets, tours, meetings and interviews from Events.\n\n'
          'Times are yours when the email gives an exact time; a flight or a '
          'hotel shows the time at the place. Something marked "Not a …" on '
          'its page is left out here too.\n\n'
          'Tap an item to read its email. "Add to calendar" hands it to your '
          'own calendar app; nothing is sent anywhere.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

final class _CalendarViewState extends State<CalendarView> {
  late final CalendarModel _model = CalendarModel(
    widget.controller.services,
    now: widget.now,
  );
  bool _showPast = false;

  /// The month shown above the list (its first day).
  late DateTime _month = DateTime(_model.today.year, _model.today.month);

  /// The day picked in the month: only it is listed.
  DateTime? _picked;

  @override
  void initState() {
    super.initState();
    _model.load();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _open(CalendarItem item) async {
    final message = widget.controller.services.store.messages.byId(
      item.messageId,
    );
    if (message == null) return;
    await EmailPage.open(context, widget.controller, message, title: 'Email');
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: ListenableBuilder(
      listenable: _model,
      builder: (context, _) => switch (_model.state) {
        Loading() || LoadFailed() => const SkeletonRows(
          label: 'Putting the calendar together…',
          maxWidth: PageScaffold.width,
        ),
        Loaded() => _list(context),
      },
    ),
  );

  Widget _list(BuildContext context) {
    final now = _model.now();
    final upcoming = _model.upcoming;
    final past = _model.past;
    final picked = _picked;
    Widget day(CalendarDay d, {bool over = false}) => _DaySection(
      key: ValueKey('calendar-day-${d.day.toIso8601String()}'),
      day: d.day,
      items: d.items,
      now: now,
      over: over,
      onOpen: _open,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PageScaffold.width),
        child: ListView(
          key: const ValueKey('calendar-list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (_model.items.isEmpty)
              const _Empty()
            else ...[
              _MonthGrid(
                month: _month,
                today: _model.today,
                busy: _model.busyDays(_month),
                picked: picked,
                onMonth: (m) => setState(() => _month = m),
                onPick: (d) => setState(() => _picked = d == picked ? null : d),
              ),
              if (picked != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: InputChip(
                      label: Text(_dayLabel(picked, now: now)),
                      onDeleted: () => setState(() => _picked = null),
                      deleteButtonTooltipMessage: 'Show every day',
                    ),
                  ),
                ),
                if (_model.on(picked) case final items when items.isNotEmpty)
                  day((
                    day: picked,
                    items: items,
                  ), over: picked.isBefore(_model.today))
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Nothing on this day')),
                  ),
              ] else ...[
                if (upcoming.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Nothing coming up')),
                  ),
                for (final d in upcoming) day(d),
                if (past.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('calendar-past'),
                      onPressed: () => setState(() => _showPast = !_showPast),
                      child: Text(_showPast ? 'Hide past' : 'Show past'),
                    ),
                  ),
                  if (_showPast)
                    for (final d in past) day(d, over: true),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// "Today", "Tomorrow", else "Tue 12 Nov" (with the year when not
/// [now]'s).
String _dayLabel(DateTime day, {required DateTime now}) {
  final today = DateTime.utc(now.year, now.month, now.day);
  return switch (DateTime.utc(
    day.year,
    day.month,
    day.day,
  ).difference(today).inDays) {
    0 => 'Today',
    1 => 'Tomorrow',
    -1 => 'Yesterday',
    _ => BookingText.day(day, now: now),
  };
}

/// One day's heading and what is on it.
final class _DaySection extends StatelessWidget {
  const _DaySection({
    super.key,
    required this.day,
    required this.items,
    required this.now,
    required this.onOpen,
    this.over = false,
  });

  final DateTime day;
  final List<CalendarItem> items;
  final DateTime now;
  final bool over;
  final void Function(CalendarItem item) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
          child: Semantics(
            header: true,
            child: Text(
              _dayLabel(day, now: now),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        for (final i in items)
          _ItemTile(item: i, over: over, now: now, onOpen: () => onOpen(i)),
      ],
    );
  }
}

/// One item: an icon for its kind, the time, what it is, and where.
final class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.now,
    required this.onOpen,
    this.over = false,
  });

  final CalendarItem item;
  final DateTime now;
  final VoidCallback onOpen;
  final bool over;

  IconData get _icon => switch (item.item) {
    final Booking b => BookingText.icon(b.kind),
    final Appointment a => AppointmentWords.icon(a.kind),
    final Event e => EventWords.icon(e.kind),
    _ => AppIcons.event,
  };

  String get _title => switch (item.item) {
    final Booking b when item.checkOut => 'Check out: ${BookingText.title(b)}',
    final Booking b => BookingText.title(b),
    final Appointment a => a.title,
    final Event e => e.title,
    _ => '',
  };

  /// "3:30 PM", "3:30 – 4:15 PM", "All day".
  String _time(BuildContext context) {
    final start = item.start;
    if (!start.hasTime) return 'All day';
    final String Function(PlaceTime) time = switch (item.source) {
      CalendarSource.trip => (t) => BookingText.time(context, t),
      _ => (t) => AppointmentWords.time(context, t),
    };
    final end = item.end;
    // A stay's check-in shows alone; its check-out has its own row.
    if (end == null ||
        !end.hasTime ||
        end.day != start.day ||
        end.compareTo(start) <= 0) {
      return time(start);
    }
    return '${time(start)} – ${time(end)}';
  }

  String _detail(BuildContext context) => switch (item.item) {
    final Booking b => BookingText.detail(context, b),
    final Appointment a => AppointmentWords.detail(a),
    final Event e => EventWords.detail(e),
    _ => '',
  };

  CalendarInvite? _invite() {
    final stamp = now.toUtc();
    return switch (item.item) {
      final Booking b => BookingCalendar.invite(b, now: stamp),
      final Appointment a => AppointmentCalendar.invite(a, now: stamp),
      final Event e => EventCalendar.invite(e, now: stamp),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cancelled = item.cancelled;
    final detail = _detail(context);
    final title = _title;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('calendar-${item.key}'),
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        onTap: onOpen,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: over || cancelled
                ? colors.surfaceContainerHighest
                : colors.primaryContainer,
            borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          ),
          child: Icon(
            _icon,
            color: over || cancelled
                ? colors.onSurfaceVariant
                : colors.onPrimaryContainer,
          ),
        ),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            decoration: cancelled ? TextDecoration.lineThrough : null,
            color: over ? colors.onSurfaceVariant : null,
          ),
        ),
        subtitle: Text(
          [_time(context), if (detail.isNotEmpty) detail].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: cancelled
            ? const AppBadge('Cancelled', tone: BadgeTone.danger)
            : CalendarFiles.canOpen && !over
            ? IconButton(
                tooltip: 'Add to calendar',
                icon: const Icon(AppIcons.addToCalendar),
                onPressed: () => addToCalendar(context, _invite()),
              )
            : null,
      ),
    );
  }
}

/// A month, Monday first, with a dot under each day that has something
/// on; arrows go to the month before and after.
final class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.today,
    required this.busy,
    required this.picked,
    required this.onMonth,
    required this.onPick,
  });

  final DateTime month;
  final DateTime today;
  final Set<DateTime> busy;
  final DateTime? picked;
  final ValueChanged<DateTime> onMonth;
  final ValueChanged<DateTime> onPick;

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final material = MaterialLocalizations.of(context);
    final first = DateTime(month.year, month.month);
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final lead = first.weekday - 1;
    final cells = <Widget>[
      for (final w in _weekdays)
        Center(
          child: ExcludeSemantics(
            child: Text(
              w,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var d = 1; d <= days; d++)
        _DayCell(
          day: DateTime(month.year, month.month, d),
          today: today,
          busy: busy.contains(DateTime(month.year, month.month, d)),
          picked: picked == DateTime(month.year, month.month, d),
          onTap: onPick,
        ),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  icon: const Icon(AppIcons.chevronLeft),
                  onPressed: () =>
                      onMonth(DateTime(month.year, month.month - 1)),
                ),
                Expanded(
                  child: Text(
                    material.formatMonthYear(first),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  icon: const Icon(AppIcons.chevron),
                  onPressed: () =>
                      onMonth(DateTime(month.year, month.month + 1)),
                ),
              ],
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final cell = constraints.maxWidth / 7;
                return Wrap(
                  children: [
                    for (final c in cells)
                      SizedBox(width: cell, height: 40, child: c),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

final class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.today,
    required this.busy,
    required this.picked,
    required this.onTap,
  });

  final DateTime day;
  final DateTime today;
  final bool busy;
  final bool picked;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isToday = day == today;
    final material = MaterialLocalizations.of(context);
    return Semantics(
      button: true,
      selected: picked,
      label:
          '${material.formatFullDate(day)}'
          '${busy ? ', something on' : ''}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('calendar-cell-${day.toIso8601String()}'),
        borderRadius: BorderRadius.circular(CitusmailTheme.radius),
        onTap: () => onTap(day),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: picked ? colors.primary : null,
            border: isToday && !picked
                ? Border.all(color: colors.primary)
                : null,
            borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: FittedBox(
                  child: Text(
                    '${day.day}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: picked ? colors.onPrimary : null,
                      fontWeight: isToday ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: busy
                      ? (picked ? colors.onPrimary : colors.primary)
                      : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        children: [
          Icon(
            AppIcons.calendar,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('Nothing on the calendar', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Trips, appointments, tickets and meetings show here, by day, '
            'once their emails are in your mail.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
