// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/detail_scaffold.dart';
import '../../inbox/state/mail_controller.dart';
import '../../reader/ui/calendar_files.dart';
import '../../reader/ui/email_page.dart';
import '../../reader/ui/link_opener.dart';
import 'add_to_calendar.dart';
import 'appointment_text.dart';
import 'event_text.dart';

/// What the user chose on an event's page; the list carries it out and
/// offers Undo.
enum EventAction { notAnEvent }

/// One event: when (in the user's time zone), where or the call's link,
/// the reference to copy, "Add to calendar", the email's own links
/// (opened after asking), and the emails behind it, each opening right
/// here. Pops with an [EventAction] when the user chose one.
final class EventDetailPage extends StatelessWidget {
  const EventDetailPage({
    super.key,
    required this.event,
    required this.controller,
    required this.messageById,
    this.now,
  });

  final Event event;
  final MailController controller;
  final StoredMessage? Function(MessageId id) messageById;

  /// Now (tests).
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

  /// A link from the email (the tickets, joining the call), after asking.
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
    final colors = Theme.of(context).colorScheme;
    final e = event;
    final today = (now ?? DateTime.now)();
    final material = MaterialLocalizations.of(context);
    final reference = e.reference;
    final day = AppointmentWords.day(e.start, now: today);
    final link = e.link;
    final facts = <Widget>[
      DetailFact.wide(
        label: 'When',
        value: [
          day == 'Today' || day == 'Tomorrow'
              ? '$day, ${AppointmentWords.date(e.start, now: today)}'
              : day,
          EventWords.hours(context, e),
        ].join('\n'),
      ),
      if (e.venue case final v?) DetailFact.wide(label: 'Where', value: v),
      if (link != null)
        DetailFact.wide(
          label: 'Online',
          value: link.host,
          trailing: IconButton(
            tooltip: 'Copy link',
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.copy, size: 18),
            onPressed: () => _copy(context, link.toString(), 'Link'),
          ),
        ),
      if (reference != null)
        DetailFact.wide(
          label: 'Reference',
          value: reference,
          trailing: IconButton(
            tooltip: 'Copy reference',
            visualDensity: VisualDensity.compact,
            icon: const Icon(AppIcons.copy, size: 18),
            onPressed: () => _copy(context, reference, 'Reference'),
          ),
          onTap: () => _copy(context, reference, 'Reference'),
        ),
      DetailFact.wide(
        label: 'From',
        value: e.latest.email.senderName ?? e.sender,
      ),
    ];

    return DetailScaffold(
      title: e.title,
      header: DetailHeader(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: e.cancelled
              ? colors.errorContainer
              : colors.primaryContainer,
          foregroundColor: e.cancelled
              ? colors.onErrorContainer
              : colors.onPrimaryContainer,
          child: Icon(EventWords.icon(e.kind)),
        ),
        title: e.title,
        struck: e.cancelled,
        subtitle: e.cancelled
            ? 'Cancelled'
            : EventWords.when(context, e.start, now: today),
        subtitleColor: e.cancelled ? colors.error : null,
        notes: [
          if (e.cancelled)
            'An email says this was cancelled.'
          else if (e.previousStart case final was?)
            'It was moved. It was ${EventWords.when(context, was, now: today)}.',
        ],
        facts: facts,
        footer: [
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (link != null && !e.cancelled)
                FilledButton.icon(
                  onPressed: () => _openLink(context, link),
                  icon: const Icon(AppIcons.videoCall, size: 18),
                  label: const Text('Join'),
                ),
              if (CalendarFiles.canOpen && !e.cancelled)
                FilledButton.tonalIcon(
                  onPressed: () => addToCalendar(
                    context,
                    EventCalendar.invite(
                      e,
                      now: (now ?? DateTime.now)().toUtc(),
                    ),
                  ),
                  icon: const Icon(AppIcons.addToCalendar, size: 18),
                  label: const Text('Add to calendar'),
                ),
              for (final l in e.links)
                if (l.url != link)
                  OutlinedButton.icon(
                    onPressed: () => _openLink(context, l.url),
                    icon: const Icon(AppIcons.openExternal, size: 18),
                    label: Text(l.label),
                  ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, EventAction.notAnEvent),
          icon: const Icon(AppIcons.hide, size: 18),
          label: const Text('Not an event'),
        ),
      ],
      children: [
        DetailSection(
          title: 'Emails',
          children: [
            for (final (i, r) in e.records.indexed)
              ListTile(
                key: ValueKey('event-email-${r.email.messageId.value}'),
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
                      ? 'Moved'
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
