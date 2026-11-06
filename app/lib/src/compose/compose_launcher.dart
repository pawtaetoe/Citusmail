// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_sync/mail_sync.dart';

import '../mail/send_later_times.dart';
import '../services/app_services.dart';
import '../ui/follow_up_sheet.dart';
import '../ui/send_later_sheet.dart';
import 'compose_controller.dart';
import 'compose_page.dart';

/// Opens the compose window (a large dialog on desktops, a full screen on
/// phones) and handles how it ended: undo for sends, a note for drafts.
abstract final class ComposeLauncher {
  static Future<void> open(
    BuildContext context,
    AppServices services,
    Draft draft,
  ) async {
    final controller = ComposeController(services, draft);
    // A screen of its own, on phones and desktops alike: room to write,
    // and the inbox is one Close (or Back) away.
    final result = await Navigator.of(context).push<ComposeResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ComposePage(controller: controller),
      ),
    );
    controller.dispose();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case ComposeSent(:final pending, :final followUp):
        _offerUndo(context, services, pending, followUp);
      case ComposeClosed(outcome: DraftOutcome.savedToServer):
        messenger.showSnackBar(
          const SnackBar(content: Text('Saved to Drafts.')),
        );
      case ComposeClosed(outcome: DraftOutcome.keptOnDevice):
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'This account has no Drafts folder; the draft is kept on this device.',
            ),
          ),
        );
      case ComposeClosed(outcome: DraftOutcome.discarded) || null:
        break;
    }
  }

  /// "Sending…" with Undo until the message actually leaves.
  static void _offerUndo(
    BuildContext context,
    AppServices services,
    PendingSend pending,
    FollowUp? followUp,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    final scheduled = pending.scheduledFor;
    // A scheduled message was queued on the send-later clock.
    final left = pending.undoUntil.difference(
      scheduled == null ? DateTime.now() : SendLaterTimes.clock(),
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            [
              scheduled == null
                  ? 'Sending…'
                  : '${SendLaterSheet.sendsAt(context, scheduled)}. '
                        'It waits in your Outbox.',
              if (followUp != null)
                '${FollowUpSheet.remindsAt(context, followUp.due)}.',
            ].join(' '),
          ),
          duration: left.isNegative ? Duration.zero : left,
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              final restored = services.sender.undo(pending);
              if (restored != null && followUp != null) {
                FollowUpReminders(services.store).cancel(followUp.messageId);
              }
              if (restored == null) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Too late: the message is on its way.'),
                  ),
                );
              } else if (context.mounted) {
                unawaited(open(context, services, restored));
              }
            },
          ),
        ),
      );
  }
}
