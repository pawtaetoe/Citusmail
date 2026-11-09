// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/mail_controller.dart';
import '../mail/trips_model.dart';
import '../services/app_services.dart';
import 'app_icons.dart';
import 'badge.dart';
import 'booking_detail_page.dart';
import 'booking_text.dart';
import 'page_scaffold.dart';
import 'read_ahead.dart';

/// Flights, stays, trains, buses, rental cars, tables and tickets found
/// in booking mail, put together into trips: what is coming up, each
/// with a timeline, then past trips. Found on the device, so it works
/// offline.
final class TripsPage extends StatefulWidget {
  const TripsPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<TripsPage> createState() => _TripsPageState();
}

final class _TripsPageState extends State<TripsPage> with ReadsAhead {
  late final TripsModel _model = TripsModel(
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

  /// The booking's own page; "Not a booking" there comes back here, with
  /// Undo.
  Future<void> _select(Booking b) async {
    _model.opened(b);
    final action = await Navigator.of(context).push<BookingAction>(
      MaterialPageRoute(
        builder: (_) => BookingDetailPage(
          booking: b,
          controller: widget.controller,
          messageById: _model.message,
          now: widget.now,
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case BookingAction.notABooking:
        _model.hide(b.key);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '${BookingText.title(b)} won\'t be listed as a booking',
              ),
              persist: false,
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => _model.unhide(b.key),
              ),
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'Trips',
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
          Widget card(Trip t, {bool over = false}) =>
              TripCard(trip: t, over: over, now: now, onSelect: _select);
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (_model.trips.isEmpty)
                    const _Empty()
                  else
                    _Overview(upcoming: upcoming, now: now),
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
                    for (final t in upcoming) card(t),
                  ],
                  if (past.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _showPast = !_showPast),
                        child: Text(
                          _showPast
                              ? 'Hide past trips'
                              : 'Show ${past.length} past '
                                    'trip${past.length == 1 ? '' : 's'}',
                        ),
                      ),
                    ),
                    if (_showPast) ...[
                      const _SectionTitle('Past'),
                      for (final t in past) card(t, over: true),
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
                              ? 'Hide the ones marked "not a booking"'
                              : 'Show ${_model.hiddenOnes.length} marked '
                                    '"not a booking"',
                        ),
                      ),
                    ),
                    if (_showHidden)
                      for (final b in _model.hiddenOnes)
                        ListTile(
                          leading: Icon(BookingText.icon(b.kind)),
                          title: Text(BookingText.title(b)),
                          subtitle: Text(
                            _model.learned.contains(b.key)
                                ? 'Left out: like ones you said aren\'t '
                                      'bookings'
                                : b.records.last.email.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () => _model.unhide(b.key),
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

/// How many trips are coming up, and when the next one starts.
final class _Overview extends StatelessWidget {
  const _Overview({required this.upcoming, required this.now});

  final List<Trip> upcoming;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = upcoming.where((t) => !t.cancelled);
    // Trips away; a table or a ticket at home is a booking.
    final away = live.where((t) => t.destinations.isNotEmpty).length;
    final other = live.length - away;
    final next =
        live.where((t) => t.destinations.isNotEmpty).firstOrNull ??
        live.firstOrNull;
    String? when;
    if (next != null) {
      final today = DateTime(now.year, now.month, now.day);
      final days = next.start.day.difference(today).inDays;
      when = switch (days) {
        <= 0 => 'now',
        1 => 'tomorrow',
        _ => 'in $days days',
      };
    }
    String bookings(int n) => '$n booking${n == 1 ? '' : 's'}';
    final title = switch ((away, other)) {
      (0, 0) => 'Nothing coming up',
      (0, final n) => '${bookings(n)} coming up',
      (final n, _) => '$n trip${n == 1 ? '' : 's'} coming up',
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(AppIcons.trips, size: 32, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleLarge),
                  if (next != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        'Next: ${BookingText.tripTitle(next)}, $when',
                        if (away > 0 && other > 0) '${bookings(other)} at home',
                      ].join(' · '),
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

/// One trip: where and when, then a timeline of its bookings.
final class TripCard extends StatelessWidget {
  const TripCard({
    super.key,
    required this.trip,
    required this.onSelect,
    required this.now,
    this.over = false,
  });

  final Trip trip;
  final void Function(Booking b) onSelect;
  final DateTime now;

  /// A past trip: shown quieter.
  final bool over;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final t = trip;
    // A trip away is named by where it goes; a booking at home by when.
    final away = t.destinations.isNotEmpty;
    final range = BookingText.range(t.start.day, t.lastDay, now: now);
    // One booking at home: its own line says it all.
    final header = away || t.bookings.length > 1;
    return Card(
      key: ValueKey('trip-${t.key}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, header ? 14 : 6, 0, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        away ? BookingText.tripTitle(t) : range,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: over ? colors.onSurfaceVariant : null,
                          decoration: t.cancelled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    if (away) ...[
                      const SizedBox(width: 10),
                      Text(
                        range,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (t.cancelled) ...[
                      const SizedBox(width: 10),
                      const AppBadge('Cancelled', tone: BadgeTone.danger),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
            for (final (i, b) in t.bookings.indexed)
              _TimelineRow(
                booking: b,
                first: i == 0,
                last: i == t.bookings.length - 1,
                muted: over,
                // The whole trip says it was cancelled.
                badge: !t.cancelled,
                onTap: () => onSelect(b),
              ),
          ],
        ),
      ),
    );
  }
}

/// One booking in a trip's timeline: its icon on the line, when, what.
final class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.booking,
    required this.first,
    required this.last,
    required this.muted,
    required this.onTap,
    this.badge = true,
  });

  /// Whether to say "Cancelled" or "Changed" on it.
  final bool badge;

  final Booking booking;
  final bool first;
  final bool last;
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final b = booking;
    final line = colors.outlineVariant;
    final detail = BookingText.detail(context, b);
    return InkWell(
      key: ValueKey('booking-${b.key}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 36,
                child: Column(
                  children: [
                    Container(
                      width: 2,
                      height: 8,
                      color: first ? Colors.transparent : line,
                    ),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: b.cancelled || muted
                            ? colors.surfaceContainerHighest
                            : colors.primaryContainer,
                      ),
                      child: Icon(
                        BookingText.icon(b.kind),
                        size: 18,
                        color: b.cancelled || muted
                            ? colors.onSurfaceVariant
                            : colors.onPrimaryContainer,
                      ),
                    ),
                    Expanded(
                      child: Container(
                        width: 2,
                        color: last ? Colors.transparent : line,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        BookingText.when(context, b.start),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        BookingText.title(b),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          decoration: b.cancelled
                              ? TextDecoration.lineThrough
                              : null,
                          color: muted || b.cancelled
                              ? colors.onSurfaceVariant
                              : null,
                        ),
                      ),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (badge && b.cancelled)
                const Center(
                  child: AppBadge('Cancelled', tone: BadgeTone.danger),
                )
              else if (badge && b.changed)
                const Center(
                  child: AppBadge('Changed', tone: BadgeTone.warning),
                ),
              const Center(child: Icon(AppIcons.chevron)),
            ],
          ),
        ),
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
                const Icon(AppIcons.trips),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Some bookings may be missing. They can be found in '
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
            AppIcons.trips,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No trips found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Flights, hotels, train and bus tickets, rental cars, '
            'restaurant tables and event tickets show here once their '
            'confirmation emails are in your mail.',
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
      'device. Many airlines, hotels and booking sites add the booking '
      'details to their emails for mail apps to read; for some others, '
      'the booking reference, flight numbers, airports, dates and '
      'check-in and check-out are read from the email. When unsure, it '
      'leaves the email out.\n\n'
      'Bookings a few days apart in the same place are put together as '
      'one trip. Times are the local times of the place, as the booking '
      'gives them. A cancellation or a schedule change updates the '
      'booking. Nothing is sent anywhere. If something listed is not a '
      'booking, open it and choose "Not a booking".',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}
