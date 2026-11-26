// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// Asks before deleting [count] messages for good (in Trash, or on an
/// account with no Trash folder, where the server deletes at once).
Future<bool> confirmDeleteForever(BuildContext context, {int count = 1}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete forever?'),
      content: Text(
        count == 1
            ? 'This message will be deleted from the server and can\'t be '
                  'recovered.'
            : 'These $count messages will be deleted from the server and '
                  'can\'t be recovered.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
