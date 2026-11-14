// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../mail/mail_controller.dart';
import 'app_icons.dart';
import 'calendar_files.dart';
import 'citusmail_theme.dart';
import 'link_opener.dart';

/// A meeting invitation (or its cancellation, or someone's answer to the
/// user's own) as a card above the message: what, when, where, who, and
/// Accept / Maybe / Decline when the user is invited. Nothing is sent
/// until they tap an answer, and then only to the organizer.
final class InvitationCard extends StatelessWidget {
  const InvitationCard({
    super.key,
    required this.controller,
    required this.reader,
    required this.invite,
  });

  final MailController controller;
  final ReaderReady reader;
  final CalendarInvite invite;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.invitationsChanged,
    builder: (context, _, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = theme.textTheme;
    final when = CalendarText(
      use24Hour: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final me = controller.ownAttendee(reader.message, invite);
    final answered =
        controller.invitationAnswers.of(invite) ??
        switch (me?.answer) {
          final a?
              when a == CalendarAnswer.accepted ||
                  a == CalendarAnswer.tentative ||
                  a == CalendarAnswer.declined =>
            a,
          _ => null,
        };
    final cancelled = invite.cancelled;
    final isReply = invite.method == CalendarMethod.reply;
    final canAnswer =
        invite.answerable &&
        me != null &&
        !invite.organizedBy(controller.ownAddresses);
    final scam = reader.trust.level == TrustLevel.danger;

    final (IconData kindIcon, String kind) = cancelled
        ? (AppIcons.eventCancelled, 'This event was cancelled')
        : isReply
        ? (AppIcons.eventReply, 'Answer to your invitation')
        : invite.method == CalendarMethod.request
        ? (AppIcons.event, 'Invitation')
        : (AppIcons.event, 'Event');
    final kindColor = cancelled ? colors.error : colors.primary;
    final location = invite.location;
    final link = invite.meetingLink;
    final description = invite.description;

    return Semantics(
      container: true,
      label: kind,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(CitusmailTheme.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(kindIcon, size: 18, color: kindColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    kind,
                    style: text.labelLarge?.copyWith(color: kindColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              invite.summary ?? '(no title)',
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                decoration: cancelled ? TextDecoration.lineThrough : null,
              ),
            ),
            const SizedBox(height: 10),
            _Line(
              icon: AppIcons.time,
              text: when.when(invite),
              notes: [?when.recurrence(invite), ?when.zoneNote(invite)],
            ),
            if (location != null && location != link?.toString())
              _Line(icon: AppIcons.place, text: location),
            if (!isReply)
              if (_people(me) case final people?)
                _Line(icon: AppIcons.people, text: people),
            if (isReply)
              for (final guest in invite.attendees.take(5))
                _Line(
                  icon: _answerIcon(guest.answer),
                  text: _theirAnswer(guest),
                  notes: [?_comment()],
                ),
            // Only when the message has no text of its own (it says the same).
            if (description != null &&
                !isReply &&
                reader.view.body.blocks.isEmpty) ...[
              const SizedBox(height: 4),
              Text(
                description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
            if (answered != null && !cancelled && !isReply) ...[
              const SizedBox(height: 10),
              _YourAnswer(answer: answered),
            ],
            if (canAnswer && !cancelled) ...[
              const SizedBox(height: 12),
              if (scam)
                Text(
                  'Answering is off: this message may be a scam, and an '
                  'answer would tell the sender your address is read.',
                  style: text.bodySmall?.copyWith(color: colors.error),
                )
              else
                _AnswerButtons(
                  chosen: answered,
                  onAnswer: (answer) => _answer(context, answer),
                  onNote: () => _answerWithNote(context),
                ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (link != null && !cancelled)
                  TextButton.icon(
                    onPressed: () => LinkOpener.open(
                      context,
                      link,
                      onMailto: controller.composeTo,
                      trust: reader.trust,
                      safety: controller.services.linkSafety.check,
                    ),
                    icon: const Icon(AppIcons.videoCall, size: 18),
                    label: Text(switch (MeetingLinks.service(link)) {
                      final name? => 'Join on $name',
                      null => 'Join online meeting',
                    }),
                  ),
                if (!isReply && CalendarFiles.canOpen)
                  TextButton.icon(
                    onPressed: () => _openInCalendar(context),
                    icon: const Icon(AppIcons.openInCalendar, size: 18),
                    label: Text(
                      cancelled
                          ? 'Remove in calendar app'
                          : 'Open in calendar app',
                    ),
                  ),
                if (!isReply)
                  TextButton.icon(
                    onPressed: () => _save(context),
                    icon: const Icon(AppIcons.save, size: 18),
                    label: const Text('Save .ics'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// "Ana Lima invited you and 2 others", "Organized by Ana Lima · 3
  /// guests"...
  String? _people(CalendarPerson? me) {
    final organizer = invite.organizer?.label;
    final guests = invite.guests.length;
    if (me != null && organizer != null) {
      final others = guests - 1;
      return others <= 0
          ? '$organizer invited you'
          : '$organizer invited you and $others '
                '${others == 1 ? 'other' : 'others'}';
    }
    final count = guests == 0
        ? null
        : '$guests ${guests == 1 ? 'guest' : 'guests'}';
    if (organizer != null) {
      return ['Organized by $organizer', ?count].join(' · ');
    }
    return count;
  }

  static String _theirAnswer(CalendarPerson guest) {
    final name = guest.shortLabel;
    return switch (guest.answer) {
      CalendarAnswer.accepted => '$name accepted',
      CalendarAnswer.tentative => '$name said maybe',
      CalendarAnswer.declined => '$name declined',
      CalendarAnswer.delegated => '$name passed it on to someone else',
      _ => '$name hasn\'t answered yet',
    };
  }

  static IconData _answerIcon(CalendarAnswer? answer) => switch (answer) {
    CalendarAnswer.accepted => AppIcons.answerYes,
    CalendarAnswer.declined => AppIcons.answerNo,
    _ => AppIcons.answerMaybe,
  };

  String? _comment() {
    final comment = invite.event.property('COMMENT')?.text.trim();
    return comment == null || comment.isEmpty ? null : '“$comment”';
  }

  void _answer(BuildContext context, CalendarAnswer answer, {String? note}) {
    final problem = controller.answerInvitation(reader, answer, note: note);
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  Future<void> _answerWithNote(BuildContext context) async {
    final result = await showDialog<(CalendarAnswer, String)>(
      context: context,
      builder: (_) =>
          _NoteDialog(organizer: invite.organizer?.label ?? 'the organizer'),
    );
    if (result == null || !context.mounted) return;
    _answer(context, result.$1, note: result.$2);
  }

  Future<void> _openInCalendar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (await CalendarFiles.open(invite)) return;
    // No calendar app took it: keep the file where the user can find it.
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

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await CalendarFiles.save(invite);
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn\'t save the event.')),
      );
    }
  }
}

/// An icon, a line of text and smaller lines under it.
final class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.notes = const []});

  final IconData icon;
  final String text;
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: theme.textTheme.bodyMedium),
                for (final note in notes)
                  Text(
                    note,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "You accepted", with a matching icon.
final class _YourAnswer extends StatelessWidget {
  const _YourAnswer({required this.answer});

  final CalendarAnswer answer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (answer) {
      CalendarAnswer.accepted => (
        AppIcons.answeredYes,
        'You accepted',
        CitusmailTheme.accent,
      ),
      CalendarAnswer.tentative => (
        AppIcons.answeredMaybe,
        'You said maybe',
        colors.onSurfaceVariant,
      ),
      _ => (AppIcons.answeredNo, 'You declined', colors.error),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Accept, Maybe and Decline (the chosen one filled), and "Add a note".
/// On phones the three share the width.
final class _AnswerButtons extends StatelessWidget {
  const _AnswerButtons({
    required this.chosen,
    required this.onAnswer,
    required this.onNote,
  });

  final CalendarAnswer? chosen;
  final void Function(CalendarAnswer answer) onAnswer;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 420;
      Widget button(CalendarAnswer answer, String label) {
        final picked = chosen == answer;
        final Widget child = picked
            ? FilledButton.tonal(
                onPressed: () => onAnswer(answer),
                child: Text(label),
              )
            : OutlinedButton(
                onPressed: () => onAnswer(answer),
                child: Text(label),
              );
        return narrow ? Expanded(child: child) : child;
      }

      final buttons = [
        button(CalendarAnswer.accepted, 'Accept'),
        const SizedBox(width: 8),
        button(CalendarAnswer.tentative, 'Maybe'),
        const SizedBox(width: 8),
        button(CalendarAnswer.declined, 'Decline'),
      ];
      final note = TextButton.icon(
        onPressed: onNote,
        icon: const Icon(AppIcons.note, size: 18),
        label: const Text('Add a note'),
      );
      if (narrow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: buttons),
            note,
          ],
        );
      }
      return Row(children: [...buttons, const SizedBox(width: 8), note]);
    },
  );
}

/// An answer with a few words for the organizer.
final class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.organizer});

  final String organizer;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

final class _NoteDialogState extends State<_NoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _send(CalendarAnswer answer) =>
      Navigator.pop(context, (answer, _note.text));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Answer with a note'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Only ${widget.organizer} gets your answer and note.'),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: 'Your note',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: () => _send(CalendarAnswer.declined),
        child: const Text('Decline'),
      ),
      OutlinedButton(
        onPressed: () => _send(CalendarAnswer.tentative),
        child: const Text('Maybe'),
      ),
      FilledButton(
        onPressed: () => _send(CalendarAnswer.accepted),
        child: const Text('Accept'),
      ),
    ],
  );
}
