// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../mail/send_later_times.dart';
import '../mail/snooze_times.dart';
import 'snooze_sheet.dart';

/// "Send later": ready-made times with the actual time next to each, and
/// "Pick date & time", with a plain word on what it takes for the message
/// to go out. A bottom sheet on phones, a small dialog on larger screens
/// (as for snoozing).
abstract final class SendLaterSheet {
  /// When to send, or null if the user closed it. [current] is the time
  /// of a scheduled message being changed.
  static Future<DateTime?> pick(BuildContext context, {DateTime? current}) {
    final panel = _SendLaterPanel(
      now: SendLaterTimes.clock(),
      current: current,
    );
    if (MediaQuery.sizeOf(context).width < SnoozeSheet.sheetWidth) {
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
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 16),
            child: panel,
          ),
        ),
      ),
    );
  }

  /// "Thu 8:00 AM", "6:00 PM" (today), "Nov 14, 8:00 AM".
  static String describe(BuildContext context, DateTime when) =>
      SnoozeTimes.describe(
        when,
        now: SendLaterTimes.clock(),
        tomorrowWord: false,
        time: (t) => MaterialLocalizations.of(context).formatTimeOfDay(
          TimeOfDay.fromDateTime(t),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        ),
      );

  /// "Sends Thu 8:00 AM", "Sends today at 6:00 PM".
  static String sendsAt(BuildContext context, DateTime when) {
    final at = when.toLocal();
    final now = SendLaterTimes.clock().toLocal();
    final today =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return today
        ? 'Sends today at ${describe(context, when)}'
        : 'Sends ${describe(context, when)}';
  }

  /// What it takes for a scheduled message to go out, honestly: the app
  /// (or, on Android, its background check) has to run at that time.
  static String get whenItGoes =>
      defaultTargetPlatform == TargetPlatform.android
      ? 'It waits in your Outbox on this phone and goes out at that time, '
            'also while Citusmail is closed (Android may hold it a few '
            'minutes to save battery). If the phone is off then, it will '
            'send when Citusmail next runs.'
      : 'It waits in your Outbox on this device and goes out at that time '
            'while Citusmail is running. If Citusmail is closed or the '
            'device is off then, it will send when Citusmail next runs.';

  /// The Outbox's note while it holds scheduled messages.
  static String get outboxNote =>
      defaultTargetPlatform == TargetPlatform.android
      ? 'Scheduled messages stay on this phone until they go out, so they '
            'are sent once, from here. Citusmail sends them in the '
            'background too; if the phone is off at that time, a message '
            'will send when Citusmail next runs.'
      : 'Scheduled messages stay on this device until they go out, so they '
            'are sent once, from here. Citusmail needs to be running at that '
            'time; if it isn\'t, a message will send when Citusmail next runs.';
}

final class _SendLaterPanel extends StatelessWidget {
  const _SendLaterPanel({required this.now, this.current});

  final DateTime now;
  final DateTime? current;

  static IconData _icon(SendLaterKind kind) => switch (kind) {
    SendLaterKind.morning => Icons.wb_sunny_outlined,
    SendLaterKind.afternoon => Icons.schedule,
    SendLaterKind.monday => Icons.date_range_outlined,
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
              Text(
                current == null ? 'Send later' : 'Change send time',
                style: theme.textTheme.titleLarge,
              ),
              if (current case final at?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Set for ${SendLaterSheet.describe(context, at)}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
        for (final c in SendLaterTimes.choicesAt(now))
          ListTile(
            key: ValueKey('send-later-${c.kind.name}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(_icon(c.kind)),
            title: Text(c.label),
            trailing: Text(
              SendLaterSheet.describe(context, c.at),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            onTap: () => Navigator.pop(context, c.at),
          ),
        ListTile(
          key: const ValueKey('send-later-pick'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 24),
          leading: const Icon(Icons.edit_calendar_outlined),
          title: const Text('Pick date & time'),
          onTap: () async {
            final at = await pickDateTime(
              context,
              now: now,
              current: current,
              dateHelp: 'Send on',
              timeHelp: 'Send at',
            );
            if (at != null && context.mounted) Navigator.pop(context, at);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Text(
            SendLaterSheet.whenItGoes,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}
