// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'app_icons.dart';
import 'appointment_text.dart';
import 'calendar_files.dart';
import 'link_opener.dart';
import 'subscription_detail_page.dart' show EmailPage;

/// What the user chose on an appointment's page; the list carries it out
/// and offers Undo.
enum AppointmentAction { notAnAppointment }

/// One appointment: when (in the user's time zone), where, what for, the
/// booking reference to copy, "Add to calendar", the email's own links
/// (opened after asking), and the emails behind it, each opening right
/// here. Pops with an [AppointmentAction] when the user chose one.
final class AppointmentDetailPage extends StatelessWidget {
  const AppointmentDetailPage({
    super.key,
    required this.appointment,
    required this.controller,
    required this.messageById,
    this.now,
  });

  final Appointment appointment;
  final MailController controller;
  final StoredMessage? Function(int id) messageById;

  /// Now (tests).
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

  /// Hands the appointment to the calendar app as an .ics file; if none
  /// takes it, the file is saved where the user can find it.
  Future<void> _addToCalendar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final invite = AppointmentCalendar.invite(
      appointment,
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

  /// A link from the email (manage, reschedule), after asking.
  void _openLink(BuildContext context, Uri url) => LinkOpener.open(
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
    final a = appointment;
    final today = (now ?? DateTime.now)();
    final material = MaterialLocalizations.of(context);
    final reference = a.reference;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final day = AppointmentWords.day(a.start, now: today);
    final facts = <Widget>[
      _Fact(
        label: 'When',
        value: [
          day == 'Today' || day == 'Tomorrow'
              ? '$day, ${AppointmentWords.date(a.start, now: today)}'
              : day,
          AppointmentWords.hours(context, a),
        ].join('\n'),
      ),
      if (a.online)
        const _Fact(label: 'Where', value: 'Online')
      else if (a.place case final p?)
        _Fact(label: 'Where', value: p),
      if (a.service case final s? when s != a.title)
        _Fact(label: 'For', value: s),
      if (a.business != null && a.business != a.title)
        _Fact(label: 'With', value: a.business!),
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
      if (AppointmentWords.bookedWith(a) case final w?)
        _Fact(label: 'Booked with', value: w),
    ];
    final links = a.links;

    return Scaffold(
      appBar: AppBar(title: Text(a.title)),
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
                              backgroundColor: a.cancelled
                                  ? colors.errorContainer
                                  : colors.primaryContainer,
                              foregroundColor: a.cancelled
                                  ? colors.onErrorContainer
                                  : colors.onPrimaryContainer,
                              child: Icon(AppointmentWords.icon(a.kind)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.title,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      decoration: a.cancelled
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    a.cancelled
                                        ? 'Cancelled'
                                        : AppointmentWords.when(
                                            context,
                                            a.start,
                                            now: today,
                                          ),
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: a.cancelled
                                          ? colors.error
                                          : colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (a.cancelled) ...[
                          const SizedBox(height: 12),
                          Text(
                            'An email says this appointment was cancelled.',
                            style: muted,
                          ),
                        ] else if (a.previousStart case final was?) ...[
                          const SizedBox(height: 12),
                          Text(
                            'It was moved. It was '
                            '${AppointmentWords.when(context, was, now: today)}.',
                            style: muted,
                          ),
                        ],
                        const Divider(height: 28),
                        ...facts,
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (CalendarFiles.canOpen && !a.cancelled)
                              FilledButton.tonalIcon(
                                onPressed: () => _addToCalendar(context),
                                icon: const Icon(
                                  Icons.event_available_outlined,
                                  size: 18,
                                ),
                                label: const Text('Add to calendar'),
                              ),
                            for (final l in links)
                              // The app's own button does that.
                              if (!l.label.toLowerCase().contains('calendar'))
                                OutlinedButton.icon(
                                  onPressed: () => _openLink(context, l.url),
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  label: Text(l.label),
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
                      for (final (i, r) in a.records.indexed) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        ListTile(
                          key: ValueKey(
                            'appointment-email-${r.email.messageId}',
                          ),
                          leading: Icon(
                            r.cancels
                                ? Icons.event_busy_outlined
                                : r.changes
                                ? Icons.update
                                : r.reminds
                                ? Icons.notifications_none
                                : AppIcons.mail,
                          ),
                          title: Text(
                            r.cancels
                                ? 'Cancelled'
                                : r.changes
                                ? 'Moved'
                                : r.reminds
                                ? 'Reminder'
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
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.pop(
                      context,
                      AppointmentAction.notAnAppointment,
                    ),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: const Text('Not an appointment'),
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
