// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/appointments_model.dart';
import '../mail/inbox_summary.dart';
import '../mail/mail_controller.dart';
import '../mail/trips_model.dart';
import 'app_icons.dart';
import 'appointment_detail_page.dart';
import 'appointment_text.dart';
import 'booking_detail_page.dart';
import 'booking_text.dart';
import 'citusmail_theme.dart';
import 'deliveries_page.dart';
import 'mail_text.dart';
import 'message_tile.dart';

/// The quiet line at the top of the inbox: "3 new · Code from Northwind ·
/// Parcel arriving today · Dentist at 3:00 PM", each piece with a small
/// icon. Each piece is a button that goes where it belongs; with nothing
/// to say there is no line.
final class InboxSummaryLine extends StatefulWidget {
  const InboxSummaryLine({super.key, required this.controller});

  final MailController controller;

  @override
  State<InboxSummaryLine> createState() => _InboxSummaryLineState();
}

/// What a piece says, what a screen reader says, and what a tap does.
typedef _Shown = ({
  IconData icon,
  String text,
  String label,
  VoidCallback onTap,
});

final class _InboxSummaryLineState extends State<InboxSummaryLine> {
  late final InboxSummary _summary = widget.controller.summary;

  MailController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _summary.watch();
  }

  @override
  void dispose() {
    _summary.unwatch();
    super.dispose();
  }

  void _push(WidgetBuilder page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: page));

  /// The appointment's own page; "Not an appointment" there hides it, as
  /// on the Appointments page.
  Future<void> _openAppointment(Appointment a) async {
    final action = await Navigator.of(context).push<AppointmentAction>(
      MaterialPageRoute(
        builder: (_) => AppointmentDetailPage(
          appointment: a,
          controller: _c,
          messageById: _c.services.store.messages.byId,
        ),
      ),
    );
    if (action != AppointmentAction.notAnAppointment) return;
    final model = AppointmentsModel(_c.services);
    await model.load();
    model.hide(a.key);
    _c.onNotice?.call(
      '${a.title} won\'t be listed as an appointment',
      undo: () => model.unhide(a.key),
    );
  }

  /// The booking's own page; "Not a booking" there hides it, as on the
  /// Trips page.
  Future<void> _openBooking(Booking b) async {
    final action = await Navigator.of(context).push<BookingAction>(
      MaterialPageRoute(
        builder: (_) => BookingDetailPage(
          booking: b,
          controller: _c,
          messageById: _c.services.store.messages.byId,
        ),
      ),
    );
    if (action != BookingAction.notABooking) return;
    final model = TripsModel(_c.services);
    await model.load();
    model.hide(b.key);
    _c.onNotice?.call(
      '${BookingText.title(b)} won\'t be listed as a booking',
      undo: () => model.unhide(b.key),
    );
  }

  void _openMessage(int id) {
    final message = _c.services.store.messages.byId(id);
    if (message != null) unawaited(_c.open(message));
  }

  _Shown _shown(SummaryPiece piece) => switch (piece) {
    NewMailPiece(:final count, :final first) => (
      icon: AppIcons.markUnread,
      text: '$count new',
      label: count == 1 ? '1 new email' : '$count new emails',
      onTap: () {
        if (first != null) unawaited(_c.open(first));
      },
    ),
    CodePiece(:final message, :final code) => (
      icon: AppIcons.codes,
      text: 'Code from ${MailText.sender(message)}',
      label: 'Copy the code from ${MailText.sender(message)}',
      onTap: () => unawaited(CopyCode.copy(context, code)),
    ),
    DeliveriesPiece(:final deliveries) => () {
      final text = deliveries.length == 1
          ? 'Parcel arriving today'
          : '${deliveries.length} parcels arriving today';
      return (
        icon: AppIcons.deliveries,
        text: text,
        label: '$text. Open Deliveries',
        onTap: () => _push((_) => DeliveriesPage(controller: _c)),
      );
    }(),
    AppointmentPiece(:final appointment) => () {
      final text = appointment.start.hasTime
          ? '${appointment.title} at '
                '${AppointmentWords.time(context, appointment.start)}'
          : '${appointment.title} today';
      return (
        icon: AppointmentWords.icon(appointment.kind),
        text: text,
        label: '$text. Open the appointment',
        onTap: () => unawaited(_openAppointment(appointment)),
      );
    }(),
    BookingPiece(:final booking) => () {
      final title = BookingText.title(booking);
      final text = booking.start.hasTime
          ? '$title at ${BookingText.time(context, booking.start)}'
          : '$title today';
      return (
        icon: BookingText.icon(booking.kind),
        text: text,
        label: '$text. Open the booking',
        onTap: () => unawaited(_openBooking(booking)),
      );
    }(),
    BillPiece(:final reminder) => () {
      final when = reminder.daysFrom(InboxSummary.clock()) <= 0
          ? 'today'
          : 'tomorrow';
      final text = switch (reminder.kind) {
        ReminderKind.trialEnds => '${reminder.name} trial ends $when',
        ReminderKind.renewal => '${reminder.name} renews $when',
        _ => '${reminder.name} bill due $when',
      };
      return (
        icon: switch (reminder.kind) {
          ReminderKind.trialEnds => AppIcons.trial,
          ReminderKind.renewal => AppIcons.subscriptions,
          _ => AppIcons.bill,
        },
        text: text,
        label: '$text. Open the email',
        onTap: () => _openMessage(reminder.messageId),
      );
    }(),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _summary,
    builder: (context, _) {
      final pieces = _summary.pieces;
      if (pieces.isEmpty) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final style = theme.textTheme.bodySmall?.copyWith(
        fontSize: 13,
        color: colors.onSurfaceVariant,
        height: 1.3,
      );
      return Padding(
        // The text starts over the avatars below.
        padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
        child: Semantics(
          container: true,
          explicitChildNodes: true,
          role: SemanticsRole.list,
          label: 'Summary',
          // Each piece with its icon: a piece that goes to the next line
          // takes its icon along.
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final piece in pieces)
                _Piece(
                  key: ValueKey('summary-${piece.runtimeType}'),
                  shown: _shown(piece),
                  style: piece is NewMailPiece
                      ? style?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        )
                      : style,
                ),
            ],
          ),
        ),
      );
    },
  );
}

final class _Piece extends StatelessWidget {
  const _Piece({super.key, required this.shown, required this.style});

  final _Shown shown;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    role: SemanticsRole.listItem,
    child: Semantics(
      button: true,
      label: shown.label,
      excludeSemantics: true,
      onTap: shown.onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
        onTap: shown.onTap,
        child: ConstrainedBox(
          // 48 to tap on touch screens; compact for a mouse.
          constraints: BoxConstraints(
            minHeight:
                Theme.of(context).materialTapTargetSize ==
                    MaterialTapTargetSize.padded
                ? 48
                : 28,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(shown.icon, size: 15, color: style?.color),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    shown.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
