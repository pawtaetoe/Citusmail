// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sync/mail_sync.dart';

import '../mail/follow_up_times.dart';
import '../mail/mail_controller.dart';
import '../mail/message_list_model.dart';
import 'avatar.dart';
import 'citusmail_theme.dart';
import 'follow_up_sheet.dart';

/// Follow-up reminders in the list pane: sent mail back with "No reply
/// yet" at the top of the Smart Inbox, and the "Waiting for a reply" list.
abstract final class FollowUpColors {
  /// The "No reply yet" badge and the waiting time.
  static const accent = Color(0xFF0D74CE);
}

/// "No reply yet" at the top of the Smart Inbox: sent mail that got no
/// answer in time, each with Done.
final class NoReplySection extends StatelessWidget {
  const NoReplySection({
    super.key,
    required this.rows,
    required this.controller,
  });

  final List<FollowUpRow> rows;
  final MailController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Heading(
        icon: Icons.hourglass_bottom,
        title: 'No reply yet',
        detail: rows.length == 1
            ? '1 email you sent'
            : '${rows.length} emails you sent',
      ),
      for (final row in rows) FollowUpTile(row: row, controller: controller),
      const SizedBox(height: 4),
    ],
  );
}

/// "Waiting for a reply": every follow-up, those back with "No reply yet"
/// first, then the ones waiting, soonest first.
final class FollowUpsView extends StatelessWidget {
  const FollowUpsView({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final rows = controller.list.followUps;
    final colors = Theme.of(context).colorScheme;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hourglass_bottom,
                size: 40,
                color: colors.outlineVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'Nothing is waiting for a reply. When you send an email, '
                'choose “Remind me if no reply” to have it come back if '
                'nobody answers.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    final back = [
      for (final r in rows)
        if (r.followUp.returned) r,
    ];
    final waiting = [
      for (final r in rows)
        if (!r.followUp.returned) r,
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (back.isNotEmpty) ...[
          const _Heading(
            icon: Icons.hourglass_bottom,
            title: 'No reply yet',
            detail: 'Also at the top of your inbox',
          ),
          for (final r in back) FollowUpTile(row: r, controller: controller),
        ],
        if (waiting.isNotEmpty) ...[
          _Heading(
            icon: Icons.hourglass_empty,
            title: 'Waiting',
            detail: waiting.length == 1
                ? '1 email'
                : '${waiting.length} emails',
          ),
          for (final r in waiting) FollowUpTile(row: r, controller: controller),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Text(
            'A reply in the conversation ends the reminder by itself. Your '
            'own replies and out-of-office replies don\'t count. Reminders '
            'stay on this device.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// A heading shaped like a section header: icon, name, a short detail.
final class _Heading extends StatelessWidget {
  const _Heading({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 16, 4),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Icon(icon, size: 18, color: FollowUpColors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Action { remindAgain, notNeeded, changeTime, cancel }

/// One follow-up: who it went to, the subject, when it was sent or when
/// it comes back. Back with "No reply yet": Done (and Remind me again or
/// Not needed in the menu). Waiting: Change time and Cancel. Opens the
/// sent message when it is on the device.
final class FollowUpTile extends StatelessWidget {
  const FollowUpTile({super.key, required this.row, required this.controller});

  final FollowUpRow row;
  final MailController controller;

  FollowUp get _f => row.followUp;

  Future<void> _act(BuildContext context, _Action action) async {
    switch (action) {
      case _Action.notNeeded || _Action.cancel:
        controller.endFollowUp(_f);
      case _Action.remindAgain || _Action.changeTime:
        final m = row.message;
        final picked = await FollowUpSheet.pick(
          context,
          current: _f.returned ? null : _f.due,
        );
        if (picked == null || !context.mounted) return;
        final at = picked.at;
        if (at == null) {
          controller.endFollowUp(_f);
        } else if (m != null) {
          controller.remindIfNoReply(
            m,
            at,
            FollowUpSheet.remindsAt(context, at),
          );
        } else {
          controller.followUps.remind(_f.copyWith(due: at.toUtc()));
          controller.refresh();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    final now = FollowUpTimes.clock();
    final returned = _f.returned;
    final who = FollowUpWords.recipients(_f);
    final first = _f.recipients.firstOrNull;
    final message = row.message;
    final open = message != null && controller.selected?.id == message.id;
    final when = returned
        ? FollowUpWords.sent(_f, now)
        : FollowUpSheet.remindsAt(context, _f.due);
    return Semantics(
      label: [
        'To $who',
        FollowUpWords.subject(_f),
        if (returned) 'No reply yet',
        when,
      ].join('. '),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          key: ValueKey('follow-up-${_f.messageId}'),
          color: open ? ListColors.of(context).selected : Colors.transparent,
          borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: message == null ? null : () => controller.open(message),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 36,
                    child: Avatar(
                      name: first?.displayName ?? first?.address ?? '?',
                      address: first?.address ?? '',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                'To $who',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: returned
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                            if (returned) ...[
                              const SizedBox(width: 8),
                              const NoReplyBadge(),
                            ],
                          ],
                        ),
                        Text(
                          FollowUpWords.subject(_f),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        Row(
                          children: [
                            Icon(
                              returned ? Icons.send_outlined : Icons.alarm,
                              size: 13,
                              color: returned ? muted : FollowUpColors.accent,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                when,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: returned
                                      ? muted
                                      : FollowUpColors.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (returned)
                    TextButton(
                      onPressed: () => controller.endFollowUp(_f),
                      child: const Text('Done'),
                    )
                  else
                    IconButton(
                      tooltip: 'Cancel reminder',
                      icon: const Icon(Icons.close),
                      color: muted,
                      onPressed: () => controller.endFollowUp(_f),
                    ),
                  PopupMenuButton<_Action>(
                    tooltip: 'Reminder options',
                    icon: Icon(Icons.more_vert, color: muted),
                    onSelected: (a) => _act(context, a),
                    itemBuilder: (_) => returned
                        ? const [
                            PopupMenuItem(
                              value: _Action.remindAgain,
                              child: ListTile(
                                leading: Icon(Icons.alarm_add_outlined),
                                title: Text('Remind me again…'),
                              ),
                            ),
                            PopupMenuItem(
                              value: _Action.notNeeded,
                              child: ListTile(
                                leading: Icon(Icons.do_not_disturb_on_outlined),
                                title: Text('Not needed'),
                              ),
                            ),
                          ]
                        : const [
                            PopupMenuItem(
                              value: _Action.changeTime,
                              child: ListTile(
                                leading: Icon(Icons.alarm),
                                title: Text('Change time…'),
                              ),
                            ),
                            PopupMenuItem(
                              value: _Action.cancel,
                              child: ListTile(
                                leading: Icon(Icons.alarm_off),
                                title: Text('Cancel reminder'),
                              ),
                            ),
                          ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "No reply yet" beside sent mail that came back.
final class NoReplyBadge extends StatelessWidget {
  const NoReplyBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: FollowUpColors.accent.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.hourglass_bottom,
          size: 12,
          color: FollowUpColors.accent,
        ),
        const SizedBox(width: 3),
        Text(
          'No reply yet',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: FollowUpColors.accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
