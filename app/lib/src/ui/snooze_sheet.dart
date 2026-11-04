// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import '../mail/snooze_times.dart';

/// "Snooze until…": ready-made times with the actual time next to each,
/// and "Pick date & time". A bottom sheet on phones, a small dialog on
/// larger screens.
abstract final class SnoozeSheet {
  /// The clock the choices start from (tests set a fixed one).
  static DateTime Function() clock = DateTime.now;

  /// Below this width the choices come up from the bottom, within reach.
  static const sheetWidth = 600.0;

  /// Asks when [messages] should come back, then snoozes them (or changes
  /// their time), with Undo.
  static Future<void> show(
    BuildContext context,
    MailController controller,
    List<StoredMessage> messages,
  ) async {
    final snoozable = messages.where(controller.canSnooze).toList();
    if (snoozable.isEmpty) {
      controller.onNotice?.call('Only mail in your inbox can be snoozed.');
      return;
    }
    final current = snoozable.length == 1
        ? controller.snoozedUntil(snoozable.single)
        : null;
    final until = await pick(context, current: current);
    if (until == null || !context.mounted) return;
    final when = describe(context, until);
    controller.snooze(
      snoozable,
      until,
      snoozable.length == 1
          ? 'Snoozed until $when'
          : 'Snoozed ${snoozable.length} until $when',
    );
  }

  /// When to snooze until, or null if the user closed it. [current] is
  /// the time of a snooze being changed.
  static Future<DateTime?> pick(BuildContext context, {DateTime? current}) {
    final panel = _SnoozePanel(now: clock(), current: current);
    if (MediaQuery.sizeOf(context).width < sheetWidth) {
      return showModalBottomSheet<DateTime>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SafeArea(child: SingleChildScrollView(child: panel)),
      );
    }
    return showDialog<DateTime>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 16),
            child: panel,
          ),
        ),
      ),
    );
  }

  /// "6:00 PM", "Tomorrow 8:00 AM", "Sat 9:00 AM", "Nov 14, 8:00 AM".
  static String describe(
    BuildContext context,
    DateTime when, {
    bool tomorrowWord = true,
  }) => SnoozeTimes.describe(
    when,
    now: clock(),
    tomorrowWord: tomorrowWord,
    time: (t) => MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(t),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    ),
  );
}

final class _SnoozePanel extends StatelessWidget {
  const _SnoozePanel({required this.now, this.current});

  final DateTime now;
  final DateTime? current;

  static IconData _icon(SnoozeChoiceKind kind) => switch (kind) {
    SnoozeChoiceKind.laterToday => Icons.schedule,
    SnoozeChoiceKind.tonight => Icons.nights_stay_outlined,
    SnoozeChoiceKind.tomorrow => Icons.wb_sunny_outlined,
    SnoozeChoiceKind.weekend => Icons.weekend_outlined,
    SnoozeChoiceKind.nextWeek => Icons.date_range_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final choices = SnoozeTimes.choicesAt(now);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current == null ? 'Snooze until…' : 'Change snooze time',
                style: theme.textTheme.titleLarge,
              ),
              if (current case final at?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Now coming back ${SnoozeSheet.describe(context, at)}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
        for (final c in choices)
          ListTile(
            key: ValueKey('snooze-${c.kind.name}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(_icon(c.kind)),
            title: Text(c.label),
            trailing: Text(
              SnoozeSheet.describe(context, c.at, tomorrowWord: false),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            onTap: () => Navigator.pop(context, c.at),
          ),
        ListTile(
          key: const ValueKey('snooze-pick'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(Icons.edit_calendar_outlined),
          title: const Text('Pick date & time'),
          onTap: () => _pickDateTime(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Text(
            'It comes back to the top of your inbox at that time. On your '
            'mail server it stays in the inbox, so other mail apps still '
            'show it there.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }

  Future<void> _pickDateTime(BuildContext context) async {
    final at = await pickDateTime(
      context,
      now: now,
      current: current,
      dateHelp: 'Snooze until',
      timeHelp: 'Comes back at',
    );
    if (at != null && context.mounted) Navigator.pop(context, at);
  }
}

/// "Pick date & time": a date, then a time of day (8:00 to start with),
/// up to a year ahead. Null if the user closed either, or picked a time
/// that has passed (then says so). Shared by snoozing and Send later.
Future<DateTime?> pickDateTime(
  BuildContext context, {
  required DateTime now,
  DateTime? current,
  required String dateHelp,
  required String timeHelp,
}) async {
  final start = current ?? now.add(const Duration(days: 1));
  final date = await showDatePicker(
    context: context,
    initialDate: start.isAfter(now) ? start : now,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: DateTime(now.year + 1, now.month, now.day),
    helpText: dateHelp,
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 8, minute: 0),
    helpText: timeHelp,
  );
  if (time == null || !context.mounted) return null;
  final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
  if (!at.isAfter(now)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Pick a time that is still ahead.')),
    );
    return null;
  }
  return at;
}
