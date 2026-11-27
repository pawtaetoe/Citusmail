// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// Asks before doing something that can't be taken back easily: [title],
/// an optional [message], and two buttons, [cancel] and [confirm] (in the
/// error colour when [destructive]). True only when the user confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  required String confirm,
  String cancel = 'Cancel',
  bool destructive = false,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: message == null ? null : Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirm),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
