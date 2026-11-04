// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'booking_text.dart';
import 'calendar_files.dart';
import 'link_opener.dart';
import 'subscription_detail_page.dart' show EmailPage;

/// What the user chose on a booking's page; the list carries it out and
/// offers Undo.
enum BookingAction { notABooking }

/// One booking: every detail the mail gives, the booking reference to
/// copy, "Add to calendar", and the emails behind it, each opening right
/// here. Pops with a [BookingAction] when the user chose one.
final class BookingDetailPage extends StatelessWidget {
  const BookingDetailPage({
    super.key,
    required this.booking,
    required this.controller,
    required this.messageById,
    this.now,
  });

  final Booking booking;
  final MailController controller;
  final StoredMessage? Function(int id) messageById;

  /// Today (tests).
  final DateTime Function()? now;

  Future<void> _openEmail(BuildContext context, int messageId) async {
    final message = messageById(messageId);
    if (message == null) return;
    await EmailPage.open(context, controller, message, title: 'Email');
  }

  Future<void> _copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what copied'), persist: false));
  }

  /// Hands the booking to the calendar app as an .ics file; if none takes
  /// it, the file is saved where the user can find it.
  Future<void> _addToCalendar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final invite = BookingCalendar.invite(
      booking,
      now: (now ?? DateTime.now)().toUtc(),
    );
    if (invite == null) return;
    if (await CalendarFiles.open(invite)) return;
    try {
      final file = await CalendarFiles.save(invite);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'No calendar app opened it, so it was saved to ${file.path}',
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t open or save the event.')),
      );
    }
  }

  /// The booking's own page (manage, check in), after asking.
  void _openPage(BuildContext context, Uri url) => LinkOpener.open(
    context,
    url,
    onMailto: controller.composeTo,
    safety: controller.services.linkSafety.check,
    virusTotal: controller.services.virusTotal.enabled
        ? controller.services.virusTotal.link
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final b = booking;
    final info = b.info;
    final material = MaterialLocalizations.of(context);
    final reference = b.reference;
    final url = info.url;
    String at(PlaceTime? t) => t == null ? '' : BookingText.when(context, t);
    String placeAt(ReservationPlace? p, PlaceTime? t, [List<String?>? more]) =>
        [
          if (p != null) BookingText.place(p),
          [if (t != null) at(t), ...?more?.nonNulls].join(' · '),
        ].where((s) => s.isNotEmpty).join('\n');

    final facts = <Widget>[
      if (reference != null)
        _Fact(
          label: 'Reference',
          value: reference,
          trailing: IconButton(
            tooltip: 'Copy booking reference',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copy(context, reference, 'Booking reference'),
          ),
          onTap: () => _copy(context, reference, 'Booking reference'),
        ),
      ...switch (info) {
        FlightReservationInfo() => [
          if (info.flightNumber case final n?) _Fact(label: 'Flight', value: n),
          if (b.provider case final p?) _Fact(label: 'Airline', value: p),
          _Fact(
            label: 'Departs',
            value: placeAt(info.from, info.start, [
              if (info.departureTerminal case final t?) 'Terminal $t',
              if (info.departureGate case final g?) 'Gate $g',
            ]),
          ),
          if (info.to != null || info.end != null)
            _Fact(
              label: 'Arrives',
              value: placeAt(info.to, info.end, [
                if (info.arrivalTerminal case final t?) 'Terminal $t',
              ]),
            ),
          if (info.seat case final s?) _Fact(label: 'Seat', value: s),
          if (info.ticketNumber case final t?) _Fact(label: 'Ticket', value: t),
        ],
        TransitReservationInfo() => [
          if ([?info.name, ?info.number].join(' ') case final n
              when n.isNotEmpty)
            _Fact(
              label: info.kind == ReservationKind.train ? 'Train' : 'Bus',
              value: n,
            ),
          if (b.provider case final p?) _Fact(label: 'With', value: p),
          _Fact(
            label: 'Departs',
            value: placeAt(info.from, info.start, [
              if (info.platform case final p?) 'Platform $p',
            ]),
          ),
          if (info.to != null || info.end != null)
            _Fact(label: 'Arrives', value: placeAt(info.to, info.end)),
          if (info.seat case final s?) _Fact(label: 'Seat', value: s),
          if (info.ticketNumber case final t?) _Fact(label: 'Ticket', value: t),
        ],
        LodgingReservationInfo() => [
          if (info.hotel?.address case final a?)
            _Fact(label: 'Address', value: a),
          _Fact(label: 'Check-in', value: at(info.checkin)),
          if (info.checkout != null)
            _Fact(label: 'Check-out', value: at(info.checkout)),
          if (info.room case final r?) _Fact(label: 'Room', value: r),
          if (info.telephone case final t?) _Fact(label: 'Phone', value: t),
          if (b.provider case final p?) _Fact(label: 'Booked with', value: p),
        ],
        RentalCarReservationInfo() => [
          if (info.car case final c?) _Fact(label: 'Car', value: c),
          if (b.provider case final p?) _Fact(label: 'Company', value: p),
          _Fact(label: 'Pick-up', value: placeAt(info.from, info.start)),
          if (info.to != null || info.end != null)
            _Fact(label: 'Drop-off', value: placeAt(info.to, info.end)),
        ],
        FoodEstablishmentReservationInfo() => [
          _Fact(label: 'When', value: at(info.start)),
          if (info.partySize case final n?) _Fact(label: 'People', value: '$n'),
          if (info.restaurant?.address case final a?)
            _Fact(label: 'Address', value: a),
          if (b.provider case final p?) _Fact(label: 'Booked with', value: p),
        ],
        EventReservationInfo() => [
          _Fact(label: 'When', value: at(info.start)),
          if (info.venue case final v?)
            _Fact(
              label: 'Where',
              value: {BookingText.place(v), ?v.address}.join('\n'),
            ),
          if (info.seat case final s?) _Fact(label: 'Seat', value: s),
          if (info.ticketNumber case final t?) _Fact(label: 'Ticket', value: t),
          if (b.provider case final p?) _Fact(label: 'Booked with', value: p),
        ],
      },
      if (b.underName case final n?) _Fact(label: 'Name', value: n),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(BookingText.title(b))),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundColor: b.cancelled
                                  ? colors.errorContainer
                                  : colors.primaryContainer,
                              foregroundColor: b.cancelled
                                  ? colors.onErrorContainer
                                  : colors.onPrimaryContainer,
                              child: Icon(BookingText.icon(b.kind)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    BookingText.title(b),
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      decoration: b.cancelled
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    b.cancelled
                                        ? 'Cancelled'
                                        : BookingText.when(context, b.start),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: b.cancelled
                                          ? colors.error
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (b.changed && !b.cancelled) ...[
                          const SizedBox(height: 12),
                          Text(
                            b.previousStart == null
                                ? 'This booking was changed. The details '
                                      'below are from the latest email.'
                                : 'The times changed. It was to start '
                                      '${at(b.previousStart)}.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (b.cancelled) ...[
                          const SizedBox(height: 12),
                          Text(
                            'An email says this booking was cancelled.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const Divider(height: 28),
                        ...facts,
                        if (info.start?.offset == null &&
                            info.start?.hasTime == true) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Times as written in the email.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ] else if (info.start?.hasTime == true) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Local times at each place.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (CalendarFiles.canOpen && !b.cancelled)
                              FilledButton.tonalIcon(
                                onPressed: () => _addToCalendar(context),
                                icon: const Icon(
                                  Icons.event_available_outlined,
                                  size: 18,
                                ),
                                label: const Text('Add to calendar'),
                              ),
                            if (url != null)
                              OutlinedButton.icon(
                                onPressed: () => _openPage(context, url),
                                icon: const Icon(Icons.open_in_new, size: 18),
                                label: const Text('Manage booking'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
                  child: Text(
                    'Emails',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final (i, r) in b.records.indexed) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        ListTile(
                          key: ValueKey('booking-email-${r.email.messageId}'),
                          leading: Icon(
                            r.cancels
                                ? Icons.event_busy_outlined
                                : r.changes
                                ? Icons.update
                                : Icons.mail_outline,
                          ),
                          title: Text(
                            r.cancels
                                ? 'Cancelled'
                                : r.changes
                                ? 'Changed'
                                : i == 0
                                ? 'Booked'
                                : 'Update',
                          ),
                          subtitle: Text(
                            '${material.formatMediumDate(r.email.at.toLocal())} · '
                            '${r.email.subject.isEmpty ? '(no subject)' : r.email.subject}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openEmail(context, r.email.messageId),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () =>
                        Navigator.pop(context, BookingAction.notABooking),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: const Text('Not a booking'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: trailing == null
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Text(value, style: theme.textTheme.bodyMedium),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
