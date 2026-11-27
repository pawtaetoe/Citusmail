// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/detail_scaffold.dart';
import '../../inbox/state/mail_controller.dart';
import '../../reader/ui/calendar_files.dart';
import '../../reader/ui/email_page.dart';
import '../../reader/ui/link_opener.dart';
import 'booking_text.dart';

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
  final StoredMessage? Function(MessageId id) messageById;

  /// Today (tests).
  final DateTime Function()? now;

  Future<void> _openEmail(BuildContext context, MessageId messageId) async {
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
        DetailFact.wide(
          label: 'Reference',
          value: reference,
          trailing: IconButton(
            tooltip: 'Copy booking reference',
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.copy, size: 18),
            onPressed: () => _copy(context, reference, 'Booking reference'),
          ),
          onTap: () => _copy(context, reference, 'Booking reference'),
        ),
      ...switch (info) {
        FlightReservationInfo() => [
          if (info.flightNumber case final n?)
            DetailFact.wide(label: 'Flight', value: n),
          if (b.provider case final p?)
            DetailFact.wide(label: 'Airline', value: p),
          DetailFact.wide(
            label: 'Departs',
            value: placeAt(info.from, info.start, [
              if (info.departureTerminal case final t?) 'Terminal $t',
              if (info.departureGate case final g?) 'Gate $g',
            ]),
          ),
          if (info.to != null || info.end != null)
            DetailFact.wide(
              label: 'Arrives',
              value: placeAt(info.to, info.end, [
                if (info.arrivalTerminal case final t?) 'Terminal $t',
              ]),
            ),
          if (info.seat case final s?) DetailFact.wide(label: 'Seat', value: s),
          if (info.ticketNumber case final t?)
            DetailFact.wide(label: 'Ticket', value: t),
        ],
        TransitReservationInfo() => [
          if ([?info.name, ?info.number].join(' ') case final n
              when n.isNotEmpty)
            DetailFact.wide(
              label: info.kind == ReservationKind.train ? 'Train' : 'Bus',
              value: n,
            ),
          if (b.provider case final p?)
            DetailFact.wide(label: 'With', value: p),
          DetailFact.wide(
            label: 'Departs',
            value: placeAt(info.from, info.start, [
              if (info.platform case final p?) 'Platform $p',
            ]),
          ),
          if (info.to != null || info.end != null)
            DetailFact.wide(
              label: 'Arrives',
              value: placeAt(info.to, info.end),
            ),
          if (info.seat case final s?) DetailFact.wide(label: 'Seat', value: s),
          if (info.ticketNumber case final t?)
            DetailFact.wide(label: 'Ticket', value: t),
        ],
        LodgingReservationInfo() => [
          if (info.hotel?.address case final a?)
            DetailFact.wide(label: 'Address', value: a),
          DetailFact.wide(label: 'Check-in', value: at(info.checkin)),
          if (info.checkout != null)
            DetailFact.wide(label: 'Check-out', value: at(info.checkout)),
          if (info.room case final r?) DetailFact.wide(label: 'Room', value: r),
          if (info.telephone case final t?)
            DetailFact.wide(label: 'Phone', value: t),
          if (b.provider case final p?)
            DetailFact.wide(label: 'Booked with', value: p),
        ],
        RentalCarReservationInfo() => [
          if (info.car case final c?) DetailFact.wide(label: 'Car', value: c),
          if (b.provider case final p?)
            DetailFact.wide(label: 'Company', value: p),
          DetailFact.wide(
            label: 'Pick-up',
            value: placeAt(info.from, info.start),
          ),
          if (info.to != null || info.end != null)
            DetailFact.wide(
              label: 'Drop-off',
              value: placeAt(info.to, info.end),
            ),
        ],
        FoodEstablishmentReservationInfo() => [
          DetailFact.wide(label: 'When', value: at(info.start)),
          if (info.partySize case final n?)
            DetailFact.wide(label: 'People', value: '$n'),
          if (info.restaurant?.address case final a?)
            DetailFact.wide(label: 'Address', value: a),
          if (b.provider case final p?)
            DetailFact.wide(label: 'Booked with', value: p),
        ],
        EventReservationInfo() => [
          DetailFact.wide(label: 'When', value: at(info.start)),
          if (info.venue case final v?)
            DetailFact.wide(
              label: 'Where',
              value: {BookingText.place(v), ?v.address}.join('\n'),
            ),
          if (info.seat case final s?) DetailFact.wide(label: 'Seat', value: s),
          if (info.ticketNumber case final t?)
            DetailFact.wide(label: 'Ticket', value: t),
          if (b.provider case final p?)
            DetailFact.wide(label: 'Booked with', value: p),
        ],
      },
      if (b.underName case final n?) DetailFact.wide(label: 'Name', value: n),
    ];

    final small = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return DetailScaffold(
      title: BookingText.title(b),
      header: DetailHeader(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: b.cancelled
              ? colors.errorContainer
              : colors.primaryContainer,
          foregroundColor: b.cancelled
              ? colors.onErrorContainer
              : colors.onPrimaryContainer,
          child: Icon(BookingText.icon(b.kind)),
        ),
        title: BookingText.title(b),
        struck: b.cancelled,
        subtitle: b.cancelled
            ? 'Cancelled'
            : BookingText.when(context, b.start),
        subtitleColor: b.cancelled ? colors.error : null,
        notes: [
          if (b.changed && !b.cancelled)
            b.previousStart == null
                ? 'This booking was changed. The details below are from the '
                      'latest email.'
                : 'The times changed. It was to start ${at(b.previousStart)}.',
          if (b.cancelled) 'An email says this booking was cancelled.',
        ],
        facts: facts,
        footer: [
          if (info.start?.offset == null && info.start?.hasTime == true) ...[
            const SizedBox(height: 8),
            Text('Times as written in the email.', style: small),
          ] else if (info.start?.hasTime == true) ...[
            const SizedBox(height: 8),
            Text('Local times at each place.', style: small),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (CalendarFiles.canOpen && !b.cancelled)
                FilledButton.tonalIcon(
                  onPressed: () => _addToCalendar(context),
                  icon: const Icon(AppIcons.addToCalendar, size: 18),
                  label: const Text('Add to calendar'),
                ),
              if (url != null)
                OutlinedButton.icon(
                  onPressed: () => _openPage(context, url),
                  icon: const Icon(AppIcons.openExternal, size: 18),
                  label: const Text('Manage booking'),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, BookingAction.notABooking),
          icon: const Icon(AppIcons.hide, size: 18),
          label: const Text('Not a booking'),
        ),
      ],
      children: [
        DetailSection(
          title: 'Emails',
          children: [
            for (final (i, r) in b.records.indexed)
              ListTile(
                key: ValueKey('booking-email-${r.email.messageId.value}'),
                leading: Icon(
                  r.cancels
                      ? AppIcons.eventCancelled
                      : r.changes
                      ? AppIcons.eventChanged
                      : AppIcons.mail,
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
                trailing: const Icon(AppIcons.chevron),
                onTap: () => _openEmail(context, r.email.messageId),
              ),
          ],
        ),
      ],
    );
  }
}
