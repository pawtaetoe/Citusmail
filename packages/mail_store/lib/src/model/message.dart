// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// The shared folders messages are sorted into across all accounts.
enum MessageCategory { people, newsletters, notifications }

/// Who decided a message's category. A manual choice is never overwritten
/// by rules.
enum CategorySource { rule, provider, manual }

/// IMAP system flags as bits, plus other keywords ($Forwarded, $Junk...).
final class MessageFlags {
  const MessageFlags(this.bits, [this.keywords = const {}]);

  /// From an IMAP FLAGS list.
  factory MessageFlags.fromImap(Iterable<String> flags) {
    var bits = 0;
    final keywords = <String>{};
    for (final flag in flags) {
      final bit = _bitOf[flag.toLowerCase()];
      if (bit != null) {
        bits |= bit;
      } else if (flag != r'\Recent' && flag.isNotEmpty) {
        keywords.add(flag);
      }
    }
    return MessageFlags(bits, Set.unmodifiable(keywords));
  }

  static const int seenBit = 1,
      answeredBit = 2,
      flaggedBit = 4,
      deletedBit = 8,
      draftBit = 16;

  static const _bitOf = {
    r'\seen': seenBit,
    r'\answered': answeredBit,
    r'\flagged': flaggedBit,
    r'\deleted': deletedBit,
    r'\draft': draftBit,
  };

  static const none = MessageFlags(0);

  final int bits;
  final Set<String> keywords;

  bool get seen => bits & seenBit != 0;
  bool get answered => bits & answeredBit != 0;
  bool get flagged => bits & flaggedBit != 0;
  bool get deleted => bits & deletedBit != 0;
  bool get draft => bits & draftBit != 0;

  /// Back to an IMAP FLAGS list.
  Set<String> toImap() => {
    if (seen) r'\Seen',
    if (answered) r'\Answered',
    if (flagged) r'\Flagged',
    if (deleted) r'\Deleted',
    if (draft) r'\Draft',
    ...keywords,
  };

  MessageFlags withBit(int bit, bool on) =>
      MessageFlags(on ? bits | bit : bits & ~bit, keywords);

  @override
  bool operator ==(Object other) =>
      other is MessageFlags &&
      other.bits == bits &&
      other.keywords.length == keywords.length &&
      other.keywords.containsAll(keywords);

  @override
  int get hashCode => Object.hash(bits, Object.hashAllUnordered(keywords));
}

/// A message summary from the server, ready to store.
final class MessageSummary {
  MessageSummary({
    required this.uid,
    required this.receivedAt,
    this.messageId,
    this.inReplyTo,
    this.references = const [],
    this.subject,
    this.from,
    this.sender = const [],
    this.replyTo = const [],
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.sentAt,
    this.size = 0,
    this.flags = MessageFlags.none,
    this.modSeq,
    this.hasAttachments = false,
    this.category = MessageCategory.people,
    this.categorySource = CategorySource.rule,
    this.snippet,
    this.headers = const {},
  }) {
    if (uid < 1) throw ArgumentError.value(uid, 'uid', 'must be at least 1');
  }

  final int uid;
  final String? messageId;
  final String? inReplyTo;
  final List<String> references;
  final String? subject;
  final MailAddress? from;
  final List<MailAddress> sender;
  final List<MailAddress> replyTo;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final DateTime? sentAt;
  final DateTime receivedAt;
  final int size;
  final MessageFlags flags;
  final int? modSeq;
  final bool hasAttachments;
  final MessageCategory category;
  final CategorySource categorySource;
  final String? snippet;

  /// Selected headers (lower-case name -> values) kept for sorting,
  /// unsubscribe and phishing checks.
  final Map<String, List<String>> headers;
}

/// A stored message as the app lists it.
final class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.mailboxId,
    required this.accountId,
    required this.uid,
    required this.receivedAt,
    required this.size,
    required this.flags,
    required this.hasAttachments,
    required this.category,
    required this.categorySource,
    this.messageId,
    this.inReplyTo,
    this.references = const [],
    this.subject,
    this.from,
    this.sentAt,
    this.modSeq,
    this.snippet,
  });

  final int id;
  final int mailboxId;
  final int accountId;
  final int uid;
  final String? messageId;
  final String? inReplyTo;
  final List<String> references;
  final String? subject;
  final MailAddress? from;
  final DateTime? sentAt;
  final DateTime receivedAt;
  final int size;
  final MessageFlags flags;
  final int? modSeq;
  final bool hasAttachments;
  final MessageCategory category;
  final CategorySource categorySource;
  final String? snippet;

  @override
  String toString() => 'StoredMessage($id, mailbox $mailboxId, uid $uid)';
}
