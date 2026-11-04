// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// What automatic sorting decided a message is. Sorting is always automatic;
/// users group mail their own way with custom folders.
enum MessageCategory {
  /// Everything without a newsletter or notification signal. Stored as
  /// 'people', its name in schema versions 1 and 2, because SQLite cannot
  /// change the CHECK constraint that lists the allowed values.
  general('people'),
  newsletters('newsletters'),
  notifications('notifications'),

  /// Verification codes, sign-in links and password resets (schema 13).
  codes('codes');

  const MessageCategory(this.storageName);

  /// The value in the database.
  final String storageName;

  static MessageCategory fromStorage(String value) => values.firstWhere(
    (c) => c.storageName == value,
    orElse: () => throw FormatException('unknown category: $value'),
  );
}

/// Who decided a message's category: header rules, or the provider's own
/// labels (later).
enum CategorySource { rule, provider }

/// The Smart Inbox sections. Every inbox message is in exactly one, the
/// first that applies:
///
/// 0. [snoozed]: put away until later (see `SnoozeRepository`);
/// 1. [pinned]: flagged (`\Flagged`, a star in other mail apps);
/// 2. [codes]: by category;
/// 3. while the Screener is on: mail from a screened-out sender goes to
///    [newsletters] (or [notifications], as the user chose), and mail
///    from a first-time sender waits in [screener] (see
///    `ScreenerRepository`);
/// 4. [newsletters] and [notifications]: by category;
/// 5. [important]: General mail from someone the user has written to, a
///    reply to the user's own mail, or marked important by the server
///    (`$Important` keyword or the `\Important` folder);
/// 6. [general]: everything else.
enum SmartSection {
  pinned,
  codes,

  /// Not shown as a section: the Smart Inbox shows a "Screener" entry
  /// that opens the waiting senders.
  screener,

  /// Not shown in the inbox at all: snoozed mail waits in the "Snoozed"
  /// list until its time (see `SnoozeRepository`).
  snoozed,
  important,
  general,
  notifications,
  newsletters,
}

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
    this.category = MessageCategory.general,
    this.categorySource = CategorySource.rule,
    this.snippet,
    this.headers = const {},
    this.listId,
    this.code,
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

  /// A verification code found in the subject or preview, if any.
  final String? code;

  /// The normalized List-Id (lower case), if the message came through a
  /// mailing list (for bulk actions on a list later).
  final String? listId;

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
    this.listId,
    this.section = SmartSection.general,
    this.code,
    DateTime? listedAt,
  }) : listedAt = listedAt ?? receivedAt;

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

  /// Where lists sort it: [receivedAt], or for mail back from snooze the
  /// time it came back.
  final DateTime listedAt;

  /// Whether it came back from snooze (it is listed at that time).
  bool get backFromSnooze => listedAt.isAfter(receivedAt);
  final int size;
  final MessageFlags flags;
  final int? modSeq;
  final bool hasAttachments;

  final MessageCategory category;
  final CategorySource categorySource;
  final String? snippet;

  /// Normalized List-Id, for mailing-list messages.
  final String? listId;

  /// Where the message is in the Smart Inbox (meaningful in an inbox).
  final SmartSection section;

  /// The verification code found in the message: null when not looked
  /// for, empty when there is none.
  final String? code;

  /// [code], when there is one.
  String? get shownCode => code == null || code!.isEmpty ? null : code;

  @override
  String toString() => 'StoredMessage($id, mailbox $mailboxId, uid $uid)';
}

/// A stored message with what sorting needs, for re-sorting without
/// downloading anything.
final class SortableMessage {
  const SortableMessage({
    required this.id,
    required this.from,
    required this.headers,
    required this.mailboxUse,
    this.subject,
    this.snippet,
    this.code,
  });

  final int id;
  final MailAddress? from;
  final String? subject;
  final String? snippet;

  /// The stored code (null: not looked for yet).
  final String? code;

  /// Stored headers, lower-case names.
  final Map<String, List<String>> headers;
  final SpecialUse? mailboxUse;
}

/// A new sorting decision for a stored message (after the rules changed).
final class CategoryDecision {
  const CategoryDecision({
    required this.messageId,
    required this.category,
    required this.source,
    this.listId,
    this.code,
  });

  final int messageId;
  final MessageCategory category;
  final CategorySource source;
  final String? listId;

  /// A code found in the subject or preview; kept only where none is
  /// stored yet.
  final String? code;
}
