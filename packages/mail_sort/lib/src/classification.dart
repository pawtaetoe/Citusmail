// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// What a classifier may look at: the sender, a few headers, the subject,
/// the server's short preview (when it gives one) and the folder. Never
/// the body, so sorting works on summaries alone.
final class ClassificationInput {
  /// [headers] must use lower-case names (as fetched by sync and stored).
  const ClassificationInput({
    required this.from,
    required this.headers,
    this.mailboxUse,
    this.subject,
    this.snippet,
  });

  final MailAddress? from;
  final Map<String, List<String>> headers;
  final SpecialUse? mailboxUse;
  final String? subject;

  /// The preview text (IMAP PREVIEW), if the server sent one.
  final String? snippet;

  /// The first non-empty value of header [name] (lower case), trimmed.
  String? header(String name) {
    for (final value in headers[name] ?? const <String>[]) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  bool has(String name) => header(name) != null;

  /// The first word of header [name], lower case, without parameters or
  /// comments: `Auto-Submitted: auto-generated; x=y` -> `auto-generated`.
  String? token(String name) {
    final value = header(name);
    if (value == null) return null;
    return _firstWord.firstMatch(value)?.group(0)?.toLowerCase();
  }

  static final _firstWord = RegExp(r'^[^\s;(]+');
}

/// Why a message got its category. Kept for tests and for explaining a
/// decision to the user; not stored.
enum SortingReason {
  ownMail,
  knownService,
  autoReply,
  readReceipt,

  /// A verification code, sign-in link or password reset.
  verification,
  oneClickUnsubscribe,
  automatedSender,
  mailingList,
  bulkPrecedence,

  /// The sender's other mail is clearly sorted this way (learned on the
  /// device, see `LearnedClassifier`).
  sameSender,
  noSignal,
}

/// A classifier's decision.
final class Classification {
  const Classification(
    this.category,
    this.reason, {
    this.source = CategorySource.rule,
  });

  final MessageCategory category;
  final SortingReason reason;

  final CategorySource source;

  @override
  String toString() => 'Classification(${category.name}, ${reason.name})';
}

/// Decides General / Codes / Newsletters / Notifications from a message's
/// headers and subject.
abstract interface class MessageClassifier {
  /// Changes whenever the same input could get a different answer (new
  /// rules or service lists), so stored mail is re-sorted after updates.
  int get version;

  Classification classify(ClassificationInput input);
}
