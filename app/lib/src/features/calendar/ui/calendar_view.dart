// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math' as math;

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
import '../../../services/reminders.dart';
import '../../found/state/prices.dart';
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
    // The title lines up with the panes when they are side by side.
    maxWidth: MediaQuery.sizeOf(context).width >= CalendarView.twoPaneWidth
        ? CalendarView.maxWidth
        : PageScaffold.width,
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

  /// From this wide, the month and the agenda side by side.
  static const twoPaneWidth = 840.0;

  /// From this wide, what is on each day shows in the month too.
  static const chipsWidth = 1200.0;

  /// The widest the two panes get together, centred beyond.
  static const maxWidth = 1400.0;

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

  /// The week shown when folded to one row (its Monday).
  late DateTime _week = _mondayOf(_model.today);

  /// The whole month, or one week. Null until the user chooses: a week on
  /// a phone (the list gets the room), the month on wider screens.
  bool? _monthOpen;

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
        Loaded() => LayoutBuilder(
          builder: (context, constraints) =>
              _model.items.isNotEmpty &&
                  constraints.maxWidth >= CalendarView.twoPaneWidth
              ? _sideBySide(context, constraints.maxWidth)
              : _list(context),
        ),
      },
    ),
  );

  /// The month, or one week when [open] is false. [roomy]: side by side,
  /// with taller days and no folding; [chips] also puts what is on each
  /// day in its cell.
  Widget _grid({required bool open, double? roomy, bool chips = false}) {
    final picked = _picked;
    final weekEnd = _week.add(const Duration(days: 6));
    return _MonthGrid(
      month: _month,
      week: open ? null : _week,
      today: _model.today,
      busy: open
          ? _model.busyDays(_month)
          : {
              ..._model.busyDays(DateTime(_week.year, _week.month)),
              ..._model.busyDays(DateTime(weekEnd.year, weekEnd.month)),
            },
      picked: picked,
      cellHeight: roomy ?? _MonthGrid.phoneCellHeight,
      itemsOn: chips ? _model.on : null,
      now: _model.now(),
      onOpen: _open,
      onMonth: (m) => setState(() => _month = m),
      onWeek: (w) => setState(() => _week = w),
      // Side by side, the month always shows.
      onFold: roomy != null
          ? null
          : () => setState(() {
              _monthOpen = !open;
              // Fold to the week of what is in view, and back.
              if (open) {
                _week = _mondayOf(
                  picked ??
                      (_month.year == _model.today.year &&
                              _month.month == _model.today.month
                          ? _model.today
                          : _month),
                );
              } else {
                _month = DateTime(_week.year, _week.month);
              }
            }),
      onPick: (d) => setState(() => _picked = d == picked ? null : d),
    );
  }

  /// What is on: the day picked, else what is coming up (and the past on
  /// request), by day.
  List<Widget> _agenda() {
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
    return [
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
          day((day: picked, items: items), over: picked.isBefore(_model.today))
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
    ];
  }

  /// Phones (and anything narrow): the week or the month, then what is
  /// on, in one column.
  Widget _list(BuildContext context) => Align(
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
            LayoutBuilder(
              builder: (context, constraints) =>
                  _grid(open: _monthOpen ?? constraints.maxWidth >= 560),
            ),
            ..._agenda(),
          ],
        ],
      ),
    ),
  );

  /// Wider windows: the month on the left, staying put, with roomier
  /// days (and what is on each, from [CalendarView.chipsWidth]); what is
  /// on, scrolling on its own, on the right. As wide as the window
  /// allows, to [CalendarView.maxWidth], like the inbox's panes.
  Widget _sideBySide(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final chips = width >= CalendarView.chipsWidth;
    final content = math.min(width, CalendarView.maxWidth) - 2 * 16;
    // The agenda gets a reading column; the month takes the rest.
    final agenda = chips
        ? (content * 0.36).clamp(360.0, 480.0)
        : (content * 0.5).clamp(320.0, 560.0);
    final cellHeight = chips
        ? _DayCell.chipsHeight(scaler)
        : math.max(52.0, scaler.scale(52));
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: CalendarView.maxWidth),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            key: const ValueKey('calendar-panes'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('calendar-month-pane'),
                  padding: const EdgeInsets.only(bottom: 24),
                  child: _grid(open: true, roomy: cellHeight, chips: chips),
                ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: agenda,
                child: ListView(
                  key: const ValueKey('calendar-list'),
                  padding: const EdgeInsets.only(bottom: 32),
                  children: _agenda(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Monday of [day]'s week.
DateTime _mondayOf(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - 1));

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

/// The icon for [item]'s kind.
IconData _iconOf(CalendarItem item) => switch (item.item) {
  final Booking b => BookingText.icon(b.kind),
  final Appointment a => AppointmentWords.icon(a.kind),
  final Event e => EventWords.icon(e.kind),
  Reminder(kind: ReminderKind.billDue) => AppIcons.bill,
  Reminder(kind: ReminderKind.trialEnds) => AppIcons.trial,
  Reminder() => AppIcons.subscriptions,
  _ => AppIcons.event,
};

/// What [item] is called.
String _titleOf(CalendarItem item) => switch (item.item) {
  final Booking b when item.checkOut => 'Check out: ${BookingText.title(b)}',
  final Booking b => BookingText.title(b),
  final Appointment a => a.title,
  final Event e => e.title,
  final Reminder r => r.name,
  _ => '',
};

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

  IconData get _icon => _iconOf(item);

  String get _title => _titleOf(item);

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
    final Reminder r => switch (r.kind) {
      ReminderKind.billDue => [
        'Bill due',
        if (r.amount case final a?) Prices.format(a),
      ].join(' · '),
      ReminderKind.trialEnds => [
        'Free trial ends',
        if (r.amount case final a?) 'then ${ReminderWords.price(a, r.cadence)}',
      ].join(' · '),
      _ => [
        'Renews',
        if (r.amount case final a?) ReminderWords.price(a, r.cadence),
      ].join(' · '),
    },
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
            // Clear of the edge, where the button's own padding would be.
            ? const Padding(
                padding: EdgeInsets.only(right: 8),
                child: AppBadge('Cancelled', tone: BadgeTone.danger),
              )
            : CalendarFiles.canOpen && !over && item.item is! Reminder
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
/// on; arrows go to the month before and after. With [itemsOn] (wide
/// windows), each day lists what is on it instead of the dot.
final class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.week,
    required this.today,
    required this.busy,
    required this.picked,
    required this.onMonth,
    required this.onWeek,
    required this.onFold,
    required this.onPick,
    required this.now,
    required this.onOpen,
    this.cellHeight = phoneCellHeight,
    this.itemsOn,
  });

  /// A day's height on a phone.
  static const phoneCellHeight = 40.0;

  final DateTime month;

  /// When folded to one row: that week's Monday.
  final DateTime? week;
  final ValueChanged<DateTime> onWeek;

  /// Folds to one week and back; null when the month always shows.
  final VoidCallback? onFold;
  final DateTime today;
  final Set<DateTime> busy;
  final DateTime? picked;
  final ValueChanged<DateTime> onMonth;
  final ValueChanged<DateTime> onPick;
  final double cellHeight;

  /// What is on a day, to list in its cell.
  final List<CalendarItem> Function(DateTime day)? itemsOn;
  final DateTime now;
  final void Function(CalendarItem item) onOpen;

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final material = MaterialLocalizations.of(context);
    final week = this.week;
    final first = week ?? DateTime(month.year, month.month);
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final lead = first.weekday - 1;
    Widget cell(DateTime day) => _DayCell(
      day: day,
      today: today,
      busy: busy.contains(day),
      picked: picked == day,
      onTap: onPick,
      items: itemsOn?.call(day),
      now: now,
      onOpen: onOpen,
    );
    final cells = <Widget>[
      if (week != null)
        for (var d = 0; d < 7; d++)
          cell(DateTime(week.year, week.month, week.day + d))
      else ...[
        for (var i = 0; i < lead; i++) const SizedBox.shrink(),
        for (var d = 1; d <= days; d++)
          cell(DateTime(month.year, month.month, d)),
      ],
    ];
    final fold = onFold;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: week == null ? 'Previous month' : 'Previous week',
                  icon: const Icon(AppIcons.chevronLeft),
                  onPressed: () => week == null
                      ? onMonth(DateTime(month.year, month.month - 1))
                      : onWeek(DateTime(week.year, week.month, week.day - 7)),
                ),
                Expanded(
                  child: Text(
                    material.formatMonthYear(first),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: week == null ? 'Next month' : 'Next week',
                  icon: const Icon(AppIcons.chevron),
                  onPressed: () => week == null
                      ? onMonth(DateTime(month.year, month.month + 1))
                      : onWeek(DateTime(week.year, week.month, week.day + 7)),
                ),
                if (fold != null)
                  IconButton(
                    key: const ValueKey('calendar-fold'),
                    tooltip: week == null ? 'Show one week' : 'Show the month',
                    icon: AnimatedRotation(
                      turns: week == null ? 0.5 : 0,
                      duration: CitusMotion.of(context, CitusMotion.fold),
                      child: const Icon(AppIcons.expand),
                    ),
                    onPressed: fold,
                  ),
              ],
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth / 7;
                return Wrap(
                  children: [
                    for (final w in _weekdays)
                      SizedBox(
                        width: width,
                        height: phoneCellHeight,
                        // Over the day numbers: centred, or at the
                        // start of each wide day.
                        child: Align(
                          alignment: itemsOn == null
                              ? Alignment.center
                              : AlignmentDirectional.centerStart,
                          child: Padding(
                            padding: EdgeInsetsDirectional.only(
                              start: itemsOn == null ? 0 : 10,
                            ),
                            child: ExcludeSemantics(
                              child: Text(
                                w,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    for (final c in cells)
                      SizedBox(width: width, height: cellHeight, child: c),
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
    required this.now,
    required this.onOpen,
    this.items,
  });

  final DateTime day;
  final DateTime today;
  final bool busy;
  final bool picked;
  final ValueChanged<DateTime> onTap;

  /// What is on the day, listed in the cell (wide windows); null shows a
  /// dot when [busy].
  final List<CalendarItem>? items;
  final DateTime now;
  final void Function(CalendarItem item) onOpen;

  /// At most this many lines in a cell: items, or some and "+N more".
  static const lines = 3;

  static double _numberHeight(TextScaler scaler) => scaler.scale(20) + 4;
  static double _lineHeight(TextScaler scaler) => scaler.scale(16) + 6;

  /// A day's height with its items listed.
  static double chipsHeight(TextScaler scaler) =>
      _numberHeight(scaler) + lines * _lineHeight(scaler) + 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isToday = day == today;
    final material = MaterialLocalizations.of(context);
    final items = this.items;
    final number = Text(
      '${day.day}',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: picked ? colors.onPrimary : null,
        fontWeight: isToday ? FontWeight.w600 : null,
      ),
    );
    final decoration = BoxDecoration(
      color: picked ? colors.primary : null,
      border: isToday && !picked ? Border.all(color: colors.primary) : null,
      borderRadius: BorderRadius.circular(CitusmailTheme.radius),
    );
    final label =
        '${material.formatFullDate(day)}'
        '${switch (items?.length) {
          null => busy ? ', something on' : '',
          0 => '',
          1 => ', 1 thing on',
          final n => ', $n things on',
        }}';
    if (items == null) {
      return Semantics(
        button: true,
        selected: picked,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('calendar-cell-${day.toIso8601String()}'),
          borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          onTap: () => onTap(day),
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: decoration,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(child: FittedBox(child: number)),
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
    // Wide: the day's number at the top, then what is on it.
    final scaler = MediaQuery.textScalerOf(context);
    final more = items.length > lines ? items.length - (lines - 1) : 0;
    final shown = more > 0 ? items.take(lines - 1) : items;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The whole cell picks the day; the items on it open their emails.
          Semantics(
            button: true,
            selected: picked,
            label: label,
            excludeSemantics: true,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('calendar-cell-${day.toIso8601String()}'),
                borderRadius: BorderRadius.circular(CitusmailTheme.radius),
                onTap: () => onTap(day),
                // A faint edge, so each day's items read as its own.
                child: Ink(
                  decoration: picked || isToday
                      ? decoration
                      : BoxDecoration(
                          border: Border.all(
                            color: colors.outlineVariant.withValues(alpha: 0.5),
                          ),
                          borderRadius: BorderRadius.circular(
                            CitusmailTheme.radius,
                          ),
                        ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IgnorePointer(
                  child: SizedBox(
                    height: _numberHeight(scaler),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 4),
                        child: ExcludeSemantics(
                          child: FittedBox(child: number),
                        ),
                      ),
                    ),
                  ),
                ),
                for (final i in shown)
                  _ItemChip(
                    item: i,
                    height: _lineHeight(scaler),
                    over: i.endsAt.isBefore(now),
                    onOpen: () => onOpen(i),
                  ),
                if (more > 0)
                  SizedBox(
                    height: _lineHeight(scaler),
                    child: InkWell(
                      key: ValueKey('calendar-more-${day.toIso8601String()}'),
                      borderRadius: BorderRadius.circular(
                        CitusmailTheme.radiusMark,
                      ),
                      onTap: () => onTap(day),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '+$more more',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: picked
                                  ? colors.onPrimary
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One item in a day of the month (wide windows): its kind's icon on its
/// kind's colour, and its title, cut short. Opens its email.
final class _ItemChip extends StatelessWidget {
  const _ItemChip({
    required this.item,
    required this.height,
    required this.over,
    required this.onOpen,
  });

  final CalendarItem item;
  final double height;
  final bool over;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cancelled = item.cancelled;
    // Each page of "Found in your mail" its own tone.
    final (background, foreground) = over || cancelled
        ? (colors.surfaceContainerHighest, colors.onSurfaceVariant)
        : switch (item.source) {
            CalendarSource.trip => (
              colors.primaryContainer,
              colors.onPrimaryContainer,
            ),
            CalendarSource.appointment => (
              colors.secondaryContainer,
              colors.onSecondaryContainer,
            ),
            CalendarSource.event => (
              colors.tertiaryContainer,
              colors.onTertiaryContainer,
            ),
            CalendarSource.money => (
              colors.surfaceContainerHighest,
              colors.onSurface,
            ),
          };
    final title = _titleOf(item);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SizedBox(
        height: height - 2,
        child: Semantics(
          button: true,
          label: cancelled ? '$title, cancelled' : title,
          excludeSemantics: true,
          child: Tooltip(
            message: title,
            waitDuration: const Duration(milliseconds: 600),
            child: Material(
              color: background,
              borderRadius: BorderRadius.circular(CitusmailTheme.radiusMark),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('calendar-chip-${item.key}'),
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Icon(_iconOf(item), size: 12, color: foreground),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground,
                            decoration: cancelled
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
