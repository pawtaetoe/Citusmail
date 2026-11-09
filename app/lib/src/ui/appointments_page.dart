// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/appointments_model.dart';
import '../mail/mail_controller.dart';
import '../services/app_services.dart';
import 'app_icons.dart';
import 'appointment_detail_page.dart';
import 'appointment_text.dart';
import 'badge.dart';
import 'citusmail_theme.dart';
import 'page_scaffold.dart';
import 'read_ahead.dart';

/// Appointments found in booking mail: a dentist, a salon, a car service,
/// an interview, a class. What is coming up, then the past year, folded.
/// Found on the device, so it works offline.
final class AppointmentsPage extends StatefulWidget {
  const AppointmentsPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Now (tests).
  final DateTime Function()? now;

  @override
  State<AppointmentsPage> createState() => _AppointmentsPageState();
}

final class _AppointmentsPageState extends State<AppointmentsPage>
    with ReadsAhead {
  late final AppointmentsModel _model = AppointmentsModel(
    widget.controller.services,
    now: widget.now,
  );
  bool _showPast = false;
  bool _showHidden = false;

  @override
  AppServices get services => widget.controller.services;

  @override
  Future<void> reload() => _model.load();

  @override
  void initState() {
    super.initState();
    _model.load().then((_) => loadedWith(_model.toRead));
  }

  @override
  void dispose() {
    _model.stopReading();
    _model.dispose();
    super.dispose();
  }

  /// The appointment's own page; "Not an appointment" there comes back
  /// here, with Undo.
  Future<void> _select(Appointment a) async {
    _model.opened(a);
    final action = await Navigator.of(context).push<AppointmentAction>(
      MaterialPageRoute(
        builder: (_) => AppointmentDetailPage(
          appointment: a,
          controller: widget.controller,
          messageById: _model.message,
          now: widget.now,
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case AppointmentAction.notAnAppointment:
        _model.hide(a.key);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('${a.title} won\'t be listed as an appointment'),
              persist: false,
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => _model.unhide(a.key),
              ),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'Appointments',
    help: (
      tooltip: 'How is this found?',
      onPressed: () => _HowDialog.show(context),
    ),

    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: _model,
        builder: (context, _) {
          if (_model.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          final upcoming = _model.upcoming;
          final past = _model.past;
          final now = (widget.now ?? DateTime.now)();
          Widget tile(Appointment a, {bool over = false}) => AppointmentTile(
            appointment: a,
            now: now,
            over: over,
            onSelect: () => _select(a),
          );
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (upcoming.isEmpty && past.isEmpty)
                    const _Empty()
                  else
                    _Overview(comingUp: _model.comingUp, now: now),
                  if (_model.reading case final r?)
                    _Reading(
                      done: r.done,
                      total: r.total,
                      onStop: _model.stopReading,
                    )
                  else if (_model.toRead.isNotEmpty && !readsAhead)
                    _ReadOffer(
                      count: _model.toRead.length,
                      onRead: _model.readEmails,
                    )
                  else if (_model.toRead.isNotEmpty && readingAhead)
                    ReadingQuietly(
                      'Reading ${_model.toRead.length} booking email'
                      '${_model.toRead.length == 1 ? '' : 's'}…',
                    ),
                  if (upcoming.isNotEmpty) ...[
                    const _SectionTitle('Upcoming'),
                    for (final a in upcoming) tile(a),
                  ],
                  if (past.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _showPast = !_showPast),
                        child: Text(
                          _showPast
                              ? 'Hide past appointments'
                              : 'Show ${past.length} past '
                                    'appointment${past.length == 1 ? '' : 's'}',
                        ),
                      ),
                    ),
                    if (_showPast) ...[
                      const _SectionTitle('Past'),
                      for (final a in past) tile(a, over: true),
                    ],
                  ],
                  if (_model.hiddenOnes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _showHidden = !_showHidden),
                        child: Text(
                          _showHidden
                              ? 'Hide the ones marked "not an appointment"'
                              : 'Show ${_model.hiddenOnes.length} marked '
                                    '"not an appointment"',
                        ),
                      ),
                    ),
                    if (_showHidden)
                      for (final a in _model.hiddenOnes)
                        ListTile(
                          leading: Icon(AppointmentWords.icon(a.kind)),
                          title: Text(a.title),
                          subtitle: Text(
                            _model.learned.contains(a.key)
                                ? 'Left out: like ones you said aren\'t '
                                      'appointments'
                                : a.latest.email.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () => _model.unhide(a.key),
                            child: const Text('List again'),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// How many appointments are coming up, and the next one.
final class _Overview extends StatelessWidget {
  const _Overview({required this.comingUp, required this.now});

  /// Upcoming, not cancelled, the soonest first.
  final List<Appointment> comingUp;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final next = comingUp.firstOrNull;
    String? when;
    if (next != null) {
      final day = AppointmentWords.day(next.start, now: now);
      final relative = day == 'Today' || day == 'Tomorrow';
      when = [
        relative ? day.toLowerCase() : day,
        if (next.start.hasTime) AppointmentWords.time(context, next.start),
      ].join(' at ');
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(
              Icons.event_available_outlined,
              size: 32,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comingUp.isEmpty
                        ? 'Nothing coming up'
                        : '${comingUp.length} coming up',
                    style: theme.textTheme.titleLarge,
                  ),
                  if (next != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Next: ${next.title}, $when',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One appointment: its day, who it is with, when, and what for.
final class AppointmentTile extends StatelessWidget {
  const AppointmentTile({
    super.key,
    required this.appointment,
    required this.onSelect,
    required this.now,
    this.over = false,
  });

  final Appointment appointment;
  final VoidCallback onSelect;
  final DateTime now;

  /// A past one: shown quieter.
  final bool over;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final a = appointment;
    final detail = AppointmentWords.detail(a);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('appointment-${a.key}'),
        contentPadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        onTap: onSelect,
        leading: _DayChip(appointment: a, muted: over || a.cancelled),
        title: Text(
          a.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            decoration: a.cancelled ? TextDecoration.lineThrough : null,
            color: over ? colors.onSurfaceVariant : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppointmentWords.when(context, a.start, now: now),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            if (detail.isNotEmpty)
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (a.cancelled)
              const AppBadge('Cancelled', tone: BadgeTone.danger)
            else if (a.changed && !over)
              const AppBadge('Moved', tone: BadgeTone.warning),
            const SizedBox(width: 4),
            const Icon(AppIcons.chevron),
          ],
        ),
      ),
    );
  }
}

/// The day of an appointment as a small calendar leaf: "NOV / 12".
final class _DayChip extends StatelessWidget {
  const _DayChip({required this.appointment, this.muted = false});

  final Appointment appointment;
  final bool muted;

  static const _months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final d = AppointmentWords.local(appointment.start);
    final background = muted
        ? colors.surfaceContainerHighest
        : colors.primaryContainer;
    final foreground = muted
        ? colors.onSurfaceVariant
        : colors.onPrimaryContainer;
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _months[d.month - 1],
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              letterSpacing: 0.6,
            ),
          ),
          Text(
            '${d.day}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Offers to download booking emails not on the device yet.
final class _ReadOffer extends StatelessWidget {
  const _ReadOffer({required this.count, required this.onRead});

  final int count;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.event_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Some appointments may be missing. They can be found in '
                    '$count booking email${count == 1 ? '' : 's'} not on '
                    'this device yet, downloaded from your mail server '
                    '(they stay unread).',
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onRead,
                child: const Text('Read booking emails'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Reading extends StatelessWidget {
  const _Reading({
    required this.done,
    required this.total,
    required this.onStop,
  });

  final int done;
  final int total;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reading booking emails: $done of $total'),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: onStop, child: const Text('Stop')),
        ],
      ),
    ),
  );
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
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
            Icons.event_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No appointments found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Appointments show here once their confirmation emails are in '
            'your mail: a doctor or dentist, a haircut, a car service, an '
            'interview, a class.',
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

final class _HowDialog extends StatelessWidget {
  const _HowDialog();

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const _HowDialog());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How is this found?'),
    content: const Text(
      'Citusmail looks at booking emails from the last year, on this '
      'device. Some clinics, salons and booking sites add the details to '
      'their emails for mail apps to read, or attach a calendar event; for '
      'the others, a confirmation with a date and a time is read from the '
      'email. When unsure, it leaves the email out.\n\n'
      'A change, a cancellation or a reminder from the same place updates '
      'the appointment, and the newest time counts. Restaurant tables and '
      'event tickets are under Trips; meeting invitations from colleagues '
      'stay in your inbox.\n\n'
      'Nothing is sent anywhere. Links from the email open only after '
      'asking. If something listed is not an appointment, open it and '
      'choose "Not an appointment".',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}
