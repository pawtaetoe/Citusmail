// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';

import '../../../core/state/load_state.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/citusmail_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/badge.dart';
import '../../../core/widgets/page_scaffold.dart';
import '../../../core/widgets/skeleton_rows.dart';
import '../../../services/app_services.dart';
import '../../inbox/state/mail_controller.dart';
import '../../settings/ui/feature_settings.dart';
import '../../settings/ui/read_ahead.dart';
import '../state/events_model.dart';
import 'appointment_text.dart';
import 'event_detail_page.dart';
import 'event_text.dart';
import 'found_parts.dart';

/// Events found in ticket and booking mail and in invitations: a tour, a
/// concert, a show, a film, a match, an exhibition, a workshop, a
/// meeting or an interview. What is coming up, then the past year,
/// folded. Found on the device, so it works offline.
final class EventsPage extends StatefulWidget {
  const EventsPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Now (tests).
  final DateTime Function()? now;

  @override
  State<EventsPage> createState() => _EventsPageState();
}

final class _EventsPageState extends State<EventsPage> with ReadsAhead {
  late final EventsModel _model = EventsModel(
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

  /// The event's own page; "Not an event" there comes back here, with
  /// Undo.
  Future<void> _select(Event e) async {
    _model.opened(e);
    final action = await Navigator.of(context).push<EventAction>(
      MaterialPageRoute(
        builder: (_) => EventDetailPage(
          event: e,
          controller: widget.controller,
          messageById: _model.message,
          now: widget.now,
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case EventAction.notAnEvent:
        _model.hide(e.key);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            undoSnackBar(
              content: Text('${e.title} won\'t be listed as an event'),
              onUndo: () => _model.unhide(e.key),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'Events',
    help: (
      tooltip: 'How is this found?',
      onPressed: () => _HowDialog.show(context, services).then((_) {
        if (mounted) setState(() {});
      }),
    ),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: _model,
        builder: (context, _) => switch (_model.state) {
          Loading() || LoadFailed() => const SkeletonRows(
            label: 'Finding events…',
            maxWidth: PageScaffold.width,
          ),
          Loaded() => _list(context),
        },
      ),
    ),
  );

  Widget _list(BuildContext context) {
    final upcoming = _model.upcoming;
    final past = _model.past;
    final now = (widget.now ?? DateTime.now)();
    Widget tile(Event e, {bool over = false}) =>
        EventTile(event: e, now: now, over: over, onSelect: () => _select(e));
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
              ReadingEmails(
                what: 'ticket emails',
                done: r.done,
                total: r.total,
                onStop: _model.stopReading,
              )
            else if (_model.toRead.isNotEmpty && !readsAhead)
              ReadEmailsOffer(
                icon: AppIcons.ticket,
                text:
                    'Some events may be missing. They can be found in '
                    '${_model.toRead.length} email${_model.toRead.length == 1 ? '' : 's'} not on '
                    'this device yet, downloaded from your mail server '
                    '(they stay unread).',
                button: 'Read ticket emails',
                onRead: _model.readEmails,
              )
            else if (_model.toRead.isNotEmpty && readingAhead)
              ReadingQuietly(
                'Reading ${_model.toRead.length} email'
                '${_model.toRead.length == 1 ? '' : 's'}…',
              ),
            if (upcoming.isNotEmpty) ...[
              const FoundSectionTitle('Upcoming'),
              for (final e in upcoming) tile(e),
            ],
            if (past.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showPast = !_showPast),
                  child: Text(
                    _showPast
                        ? 'Hide past events'
                        : 'Show ${past.length} past '
                              'event${past.length == 1 ? '' : 's'}',
                  ),
                ),
              ),
              if (_showPast) ...[
                const FoundSectionTitle('Past'),
                for (final e in past) tile(e, over: true),
              ],
            ],
            if (_model.hiddenOnes.isNotEmpty)
              LeftOutList(
                marked: 'not an event',
                plural: 'events',
                open: _showHidden,
                onToggle: () => setState(() => _showHidden = !_showHidden),
                items: [
                  for (final e in _model.hiddenOnes)
                    (
                      leading: Icon(EventWords.icon(e.kind)),
                      title: e.title,
                      about: e.latest.email.subject,
                      learned: _model.learned.contains(e.key),
                      onListAgain: () => _model.unhide(e.key),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// How many events are coming up, and the next one.
final class _Overview extends StatelessWidget {
  const _Overview({required this.comingUp, required this.now});

  final List<Event> comingUp;
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
            Icon(AppIcons.events, size: 32, color: theme.colorScheme.primary),
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

/// One event: its day, what it is, when, and where.
final class EventTile extends StatelessWidget {
  const EventTile({
    super.key,
    required this.event,
    required this.onSelect,
    required this.now,
    this.over = false,
  });

  final Event event;
  final VoidCallback onSelect;
  final DateTime now;

  /// A past one: shown quieter.
  final bool over;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final e = event;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('event-${e.key}'),
        contentPadding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        onTap: onSelect,
        leading: DayLeaf(day: e.start, muted: over || e.cancelled),
        title: Text(
          e.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            decoration: e.cancelled ? TextDecoration.lineThrough : null,
            color: over ? colors.onSurfaceVariant : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              EventWords.when(context, e.start, now: now),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              EventWords.detail(e),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (e.cancelled)
              const AppBadge('Cancelled', tone: BadgeTone.danger)
            else if (e.changed && !over)
              const AppBadge('Moved', tone: BadgeTone.warning),
            const SizedBox(width: 4),
            const Icon(AppIcons.chevron),
          ],
        ),
      ),
    );
  }
}

/// A day as a small calendar leaf: "NOV / 12".
final class DayLeaf extends StatelessWidget {
  const DayLeaf({super.key, required this.day, this.muted = false});

  final PlaceTime day;
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
    final d = AppointmentWords.local(day);
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
            AppIcons.events,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No events found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Events show here once their tickets or invitations are in your '
            'mail: a tour, a concert, a show, a film, a match, an '
            'exhibition, a workshop, a meeting.',
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
  const _HowDialog(this.services);

  final AppServices services;

  static Future<void> show(BuildContext context, AppServices services) =>
      showDialog<void>(context: context, builder: (_) => _HowDialog(services));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How is this found?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Citusmail looks at ticket, booking and invitation emails from the '
            'last year, on this device. Some ticket sites add the details to '
            'their emails for mail apps to read, and invitations carry a '
            'calendar event; for the others, an email that confirms a booking '
            'or a ticket and gives a date is read. Sales, announcements and '
            'newsletters are left out. When unsure, it leaves the email out.\n\n'
            'A change, a cancellation or a reminder from the same sender '
            'updates the event, and the newest time counts. Appointments '
            '(a dentist, a salon) are under Appointments, and flights, hotels '
            'and tables under Trips.\n\n'
            'Nothing is sent anywhere. Links from the email open only after '
            'asking. If something listed is not an event, open it and choose '
            '"Not an event".',
          ),
          const SizedBox(height: 12),
          AutoReadSwitch(services: services),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}
