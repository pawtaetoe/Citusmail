// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_compose/mail_compose.dart';

import '../services/app_services.dart';
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
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final ComposeResult? result;
    if (wide) {
      result = await showDialog<ComposeResult>(
        context: context,
        barrierDismissible: false,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
            child: ComposePage(controller: controller),
          ),
        ),
      );
    } else {
      result = await Navigator.of(context).push<ComposeResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => ComposePage(controller: controller),
        ),
      );
    }
    controller.dispose();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case ComposeSent(:final pending):
        _offerUndo(context, services, pending);
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
  ) {
    final messenger = ScaffoldMessenger.of(context);
    final left = pending.undoUntil.difference(DateTime.now());
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Sending…'),
          duration: left.isNegative ? Duration.zero : left,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              final restored = services.sender.undo(pending);
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
