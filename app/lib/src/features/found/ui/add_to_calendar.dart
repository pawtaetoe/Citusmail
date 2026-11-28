// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_view/mail_view.dart';

import '../../reader/ui/calendar_files.dart';

/// Hands [invite] to the calendar app as an .ics file; if none takes it,
/// the file is saved where the user can find it, and a line says where.
Future<void> addToCalendar(BuildContext context, CalendarInvite? invite) async {
  if (invite == null) return;
  final messenger = ScaffoldMessenger.of(context);
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
