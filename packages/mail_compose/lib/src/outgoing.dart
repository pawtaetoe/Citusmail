// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'draft.dart';

/// Why a draft cannot be sent yet.
enum ComposeProblem {
  noRecipients,
  invalidRecipient,
  attachmentsTooLarge,
  accountMissing,
}

final class ComposeException implements Exception {
  const ComposeException(this.problems);

  final Set<ComposeProblem> problems;

  @override
  String toString() =>
      'ComposeException(${problems.map((p) => p.name).join(', ')})';
}

/// Turns drafts into messages.
final class OutgoingMessages {
  const OutgoingMessages({this.maxAttachmentBytes = defaultMaxAttachmentBytes});

  /// Most mail servers refuse messages much over 25 MB (attachments grow by
  /// a third when encoded).
  static const defaultMaxAttachmentBytes = 18 * 1024 * 1024;

  final int maxAttachmentBytes;

  /// The address the account sends from, with its display name.
  static MailAddress sender(Account account) {
    final at = account.email.lastIndexOf('@');
    return MailAddress(
      displayName: account.displayName,
      localPart: account.email.substring(0, at),
      domain: account.email.substring(at + 1),
    );
  }

  /// What stops [draft] from being sent (empty if it can be sent).
  Set<ComposeProblem> problems(Draft draft, Account? account) => {
    if (account == null) ComposeProblem.accountMissing,
    if (draft.recipients.isEmpty) ComposeProblem.noRecipients,
    if (draft.recipients.any((a) => !_valid(a)))
      ComposeProblem.invalidRecipient,
    if (draft.attachmentBytes > maxAttachmentBytes)
      ComposeProblem.attachmentsTooLarge,
  };

  /// The message to send. Throws [ComposeException] if it cannot be sent.
  BuiltMessage forSending(Draft draft, Account? account) {
    final problems = this.problems(draft, account);
    if (problems.isNotEmpty) throw ComposeException(problems);
    try {
      return MessageBuilder().build(_outgoing(draft, account!));
    } on MessageBuildException {
      throw const ComposeException({ComposeProblem.invalidRecipient});
    }
  }

  /// The copy saved in the user's Drafts folder: a new Message-ID each
  /// time, so each saved version can be told apart.
  BuiltMessage forDraftsFolder(Draft draft, Account account) =>
      MessageBuilder().build(_outgoing(draft, account), draft: true);

  static OutgoingMessage _outgoing(Draft draft, Account account) =>
      OutgoingMessage(
        from: sender(account),
        to: draft.to,
        cc: draft.cc,
        bcc: draft.bcc,
        subject: draft.subject.trim(),
        textBody: draft.body,
        attachments: [
          for (final a in draft.attachments)
            OutgoingAttachment(
              filename: a.fileName,
              mimeType: a.mimeType,
              bytes: a.bytes,
            ),
        ],
        inReplyTo: draft.inReplyTo,
        references: draft.references,
        receiptTo: draft.requestReceipt ? sender(account) : null,
      );

  /// A deliverable address: something@domain.with.dot, no spaces or
  /// control characters.
  static bool _valid(MailAddress a) =>
      a.localPart.isNotEmpty &&
      _domain.hasMatch(a.domain) &&
      !a.localPart.contains(RegExp(r'[\x00-\x1F\x7F]'));

  static final _domain = RegExp(
    r'^[^\s@\x00-\x1F\x7F.][^\s@\x00-\x1F\x7F]*\.[^\s@\x00-\x1F\x7F]+$',
  );
}
