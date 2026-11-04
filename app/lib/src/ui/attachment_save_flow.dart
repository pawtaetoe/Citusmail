// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_trust/mail_trust.dart';

import 'attachment_saver.dart';
import 'trust_banner.dart';
import 'virus_total_check.dart';

/// Saving an attachment to Downloads, from the reader or the attachments
/// page: a risky file (a program, a disk image, a document with macros, a
/// web page) is only saved after the user confirms, with "Don't save" as
/// the main button and the optional VirusTotal check. Files are never
/// opened.
abstract final class AttachmentSaveFlow {
  /// Saves [fileName] (already a safe name) with the content [bytes], and
  /// says where in a snack bar. [verdict] is what the trust checks found
  /// about the name (null: nothing).
  static Future<void> save(
    BuildContext context, {
    required String fileName,
    required List<int> Function() bytes,
    AttachmentVerdict? verdict,
    Future<VirusTotalReport> Function(List<int> bytes)? virusTotal,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    if (verdict != null &&
        !await _confirm(context, verdict, bytes, virusTotal)) {
      return;
    }
    try {
      final file = await AttachmentSaver.saveBytes(fileName, bytes());
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t save $fileName.')),
      );
    }
  }

  /// Asks before saving a risky file; "Don't save" is the main button.
  static Future<bool> _confirm(
    BuildContext context,
    AttachmentVerdict verdict,
    List<int> Function() bytes,
    Future<VirusTotalReport> Function(List<int> bytes)? virusTotal,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save this file anyway?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                verdict.fileName,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TrustReasons(level: verdict.level, reasons: [verdict.reason]),
              const SizedBox(height: 12),
              const Text(
                'Only open it if you were expecting it from someone you know.',
              ),
              if (virusTotal != null) ...[
                const SizedBox(height: 8),
                VirusTotalCheck(
                  what: 'file',
                  lookup: () => virusTotal(bytes()),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save anyway'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Don\'t save'),
            ),
          ],
        ),
      ) ??
      false;
}
