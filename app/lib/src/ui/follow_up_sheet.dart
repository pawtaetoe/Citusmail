// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/follow_up_times.dart';
import '../mail/mail_controller.dart';
import '../mail/snooze_times.dart';
import 'app_icons.dart';
import 'snooze_sheet.dart';

/// What the user chose: a time, or no reminder ([at] null).
final class FollowUpPick {
  const FollowUpPick(this.at, {this.days});

  final DateTime? at;

  /// For "In 1 day", "In 3 days" and "In 1 week": the days after sending
  /// (a message sent later counts from when it goes out). Null for a
  /// picked date.
  final int? days;

  /// When it comes back for a message that goes out at [sent].
  DateTime? dueFor(DateTime sent) =>
      days == null ? at : FollowUpTimes.after(sent, days!);
}

/// "Remind me if no reply": in 1 day, 3 days, 1 week (with the date each
/// means), or a picked date. A bottom sheet on phones, a small dialog on
/// larger screens, as for snoozing.
abstract final class FollowUpSheet {
  /// The small print: what happens, and what doesn't count as a reply.
  static const explanation =
      'If nobody answers by then, the email comes back to the top of your '
      'inbox marked “No reply yet”. Your own replies and out-of-office '
      'replies don\'t count. This stays on this device.';

  /// When to be reminded about a message sent at [sent] (now, if not
  /// given), or null if the user closed it. [current] is the time already
  /// set; then "Don't remind me" is offered too.
  static Future<FollowUpPick?> pick(
    BuildContext context, {
    DateTime? sent,
    DateTime? current,
  }) {
    final panel = _FollowUpPanel(
      now: FollowUpTimes.clock(),
      sent: sent ?? FollowUpTimes.clock(),
      current: current,
    );
    if (MediaQuery.sizeOf(context).width < SnoozeSheet.sheetWidth) {
      return showModalBottomSheet<FollowUpPick>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SafeArea(child: SingleChildScrollView(child: panel)),
      );
    }
    return showDialog<FollowUpPick>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 16),
            child: panel,
          ),
        ),
      ),
    );
  }

  /// Asks when to be reminded about [m] (mail the user sent), then sets,
  /// changes or cancels it, with Undo.
  static Future<void> show(
    BuildContext context,
    MailController controller,
    StoredMessage m,
  ) async {
    final current = controller.followUpFor(m);
    final picked = await pick(
      context,
      sent: FollowUpTimes.clock(),
      current: current == null || current.returned ? null : current.due,
    );
    if (picked == null || !context.mounted) return;
    final at = picked.at;
    if (at == null) {
      if (current != null) controller.endFollowUp(current);
      return;
    }
    controller.remindIfNoReply(m, at, remindsAt(context, at));
  }

  /// "Thu 10:00 AM", "Tomorrow 10:00 AM", "Nov 14, 8:00 AM".
  static String describe(
    BuildContext context,
    DateTime when, {
    bool tomorrowWord = true,
  }) => SnoozeTimes.describe(
    when,
    now: FollowUpTimes.clock(),
    tomorrowWord: tomorrowWord,
    time: (t) => MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(t),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    ),
  );

  /// "Reminds you Thu 10:00 AM if no reply".
  static String remindsAt(BuildContext context, DateTime when) =>
      'Reminds you ${describe(context, when)} if no reply';
}

final class _FollowUpPanel extends StatelessWidget {
  const _FollowUpPanel({required this.now, required this.sent, this.current});

  final DateTime now;
  final DateTime sent;
  final DateTime? current;

  static IconData _icon(FollowUpKind kind) => switch (kind) {
    FollowUpKind.oneDay => AppIcons.oneDay,
    FollowUpKind.threeDays => AppIcons.threeDays,
    FollowUpKind.oneWeek => AppIcons.week,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Remind me if no reply', style: theme.textTheme.titleLarge),
              if (current case final at?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Set for ${FollowUpSheet.describe(context, at)}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
        for (final c in FollowUpTimes.choicesFrom(sent))
          if (c.at.isAfter(now))
            ListTile(
              key: ValueKey('follow-up-${c.kind.name}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: Icon(_icon(c.kind)),
              title: Text(c.label),
              trailing: Text(
                FollowUpSheet.describe(context, c.at, tomorrowWord: false),
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
              onTap: () =>
                  Navigator.pop(context, FollowUpPick(c.at, days: c.kind.days)),
            ),
        ListTile(
          key: const ValueKey('follow-up-pick'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(AppIcons.pickTime),
          title: const Text('Pick a date'),
          onTap: () => _pickDate(context),
        ),
        if (current != null)
          ListTile(
            key: const ValueKey('follow-up-off'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(AppIcons.remindOff),
            title: const Text('Don\'t remind me'),
            onTap: () => Navigator.pop(context, const FollowUpPick(null)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Text(
            FollowUpSheet.explanation,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }

  /// A day, up to a year ahead; it comes back that morning.
  Future<void> _pickDate(BuildContext context) async {
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final start = current ?? DateTime(now.year, now.month, now.day + 3);
    final day = await showDatePicker(
      context: context,
      initialDate: start.isBefore(tomorrow) ? tomorrow : start,
      firstDate: tomorrow,
      lastDate: DateTime(now.year + 1, now.month, now.day),
      helpText: 'Remind me on',
    );
    if (day == null || !context.mounted) return;
    Navigator.pop(context, FollowUpPick(FollowUpTimes.onDay(day)));
  }
}
