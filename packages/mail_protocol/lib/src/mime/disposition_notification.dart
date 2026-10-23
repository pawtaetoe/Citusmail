// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'mime_message.dart';

/// A read receipt (message disposition notification, RFC 8098): another
/// person's mail app reporting what happened to a message.
final class DispositionNotification {
  const DispositionNotification({
    required this.originalMessageId,
    required this.finalRecipient,
    required this.disposition,
  });

  /// The Message-ID of the message it reports on, without brackets.
  final String originalMessageId;

  /// The address the report is about, lower case.
  final String finalRecipient;

  /// `displayed`, `deleted`, `dispatched` or `processed`.
  final String disposition;

  bool get displayed => disposition == 'displayed';

  /// The notification in [message] (a `multipart/report` with
  /// `report-type=disposition-notification`), or null if it isn't one or
  /// lacks what a receipt needs.
  static DispositionNotification? fromMessage(MimeMessage message) {
    final type = message.root.contentType;
    if (type.mimeType != 'multipart/report' ||
        type.parameters['report-type']?.toLowerCase() !=
            'disposition-notification') {
      return null;
    }
    for (final part in message.root.allParts) {
      if (part.contentType.mimeType == 'message/disposition-notification') {
        return parseFields(part.decodeText().text);
      }
    }
    return null;
  }

  /// Reads the `Name: value` fields of a notification part.
  static DispositionNotification? parseFields(String text) {
    if (text.length > 64 * 1024) return null;
    final fields = <String, String>{};
    String? last;
    for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
      if (line.isEmpty) continue;
      if ((line.startsWith(' ') || line.startsWith('\t')) && last != null) {
        fields[last] = '${fields[last]} ${line.trim()}';
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      last = line.substring(0, colon).trim().toLowerCase();
      fields.putIfAbsent(last, () => line.substring(colon + 1).trim());
    }
    final original = fields['original-message-id']
        ?.replaceAll(RegExp(r'^\s*<|>\s*$'), '')
        .trim();
    final recipient = fields['final-recipient'];
    final disposition = fields['disposition'];
    if (original == null ||
        original.isEmpty ||
        original.contains(RegExp(r'[\s<>]')) ||
        recipient == null ||
        disposition == null) {
      return null;
    }
    // "rfc822;bob@x.example" -> bob@x.example
    final semicolon = recipient.indexOf(';');
    final address =
        (semicolon < 0 ? recipient : recipient.substring(semicolon + 1))
            .trim()
            .replaceAll(RegExp(r'^<|>$'), '')
            .toLowerCase();
    // "manual-action/MDN-sent-manually; displayed" -> displayed
    final semi = disposition.indexOf(';');
    final kind = (semi < 0 ? '' : disposition.substring(semi + 1))
        .trim()
        .split(RegExp(r'[/\s]'))
        .first
        .toLowerCase();
    if (!address.contains('@') ||
        !const {
          'displayed',
          'deleted',
          'dispatched',
          'processed',
        }.contains(kind)) {
      return null;
    }
    return DispositionNotification(
      originalMessageId: original,
      finalRecipient: address,
      disposition: kind,
    );
  }
}
