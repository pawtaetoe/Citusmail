// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

/// Turns FETCH results into summaries for the store.
final class SummaryMapper {
  const SummaryMapper(this.classifier);

  final MessageClassifier classifier;

  /// Headers fetched with every summary: what sorting, unsubscribe, read
  /// receipts and phishing checks need, and nothing else.
  static const headerFields = [
    'List-Id',
    'List-Unsubscribe',
    'List-Unsubscribe-Post',
    'Precedence',
    'Auto-Submitted',
    'Authentication-Results',
    'Disposition-Notification-To',
    'Feedback-ID',
    // Read receipts (RFC 8098 reports) are recognised by their type.
    'Content-Type',
  ];

  static const _maxSnippet = 200;

  /// The FETCH items a summary needs on this server.
  static FetchItems fetchItems(
    ImapCapabilities capabilities, {
    required bool modSeq,
  }) => FetchItems(
    flags: true,
    internalDate: true,
    size: true,
    envelope: true,
    bodyStructure: true,
    modSeq: modSeq,
    preview: capabilities.has('PREVIEW'),
    headerFields: headerFields,
  );

  /// A summary, or null if the server left out what every summary needs.
  MessageSummary? map(FetchedMessage message, {SpecialUse? mailboxUse}) {
    final uid = message.uid;
    final envelope = message.envelope;
    final received = message.internalDate ?? envelope?.date?.utc;
    if (uid == null || received == null) return null;

    final headers = _headers(message.headerFields);
    final from = envelope?.from.firstOrNull;
    final decision = classifier.classify(
      ClassificationInput(from: from, headers: headers, mailboxUse: mailboxUse),
    );
    return MessageSummary(
      uid: uid,
      receivedAt: received,
      sentAt: envelope?.date?.utc,
      messageId: envelope?.messageId,
      inReplyTo: envelope?.inReplyTo,
      subject: envelope?.subject,
      from: from,
      sender: envelope?.sender ?? const [],
      replyTo: envelope?.replyTo ?? const [],
      to: envelope?.to ?? const [],
      cc: envelope?.cc ?? const [],
      bcc: envelope?.bcc ?? const [],
      size: message.size ?? 0,
      flags: MessageFlags.fromImap(message.flags ?? const {}),
      modSeq: message.modSeq,
      hasAttachments:
          message.bodyStructure?.allParts.any((p) => p.isAttachment) ?? false,
      category: decision.category,
      categorySource: decision.source,
      listId: ListId.fromHeaders(headers),
      snippet: _snippet(message.preview),
      headers: headers,
    );
  }

  static Map<String, List<String>> _headers(Uint8List? raw) {
    if (raw == null || raw.isEmpty) return const {};
    final parsed = const HeaderParser().parse(raw);
    final result = <String, List<String>>{};
    for (final field in parsed.headers.fields) {
      result.putIfAbsent(field.name.toLowerCase(), () => []).add(field.value);
    }
    return result;
  }

  /// Preview text, single-line, without control characters, shortened.
  static String? _snippet(String? preview) {
    if (preview == null) return null;
    final clean = preview
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return null;
    return clean.length > _maxSnippet ? clean.substring(0, _maxSnippet) : clean;
  }
}
