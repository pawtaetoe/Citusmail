// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'classification.dart';
import 'sender_patterns.dart';

/// One header rule. Rules run in order; the first that decides wins.
abstract interface class SortingRule {
  /// The decision, or null to let the next rule decide.
  Classification? apply(ClassificationInput input);
}

/// Mail in Sent or Drafts is the user's own: always General.
final class OwnMailRule implements SortingRule {
  const OwnMailRule();

  @override
  Classification? apply(ClassificationInput input) =>
      switch (input.mailboxUse) {
        SpecialUse.sent || SpecialUse.drafts => const Classification(
          MessageCategory.general,
          SortingReason.ownMail,
        ),
        _ => null,
      };
}

/// Services such as GitHub are notifications, even though their mail has
/// mailing-list and unsubscribe headers.
final class KnownServiceRule implements SortingRule {
  const KnownServiceRule();

  @override
  Classification? apply(ClassificationInput input) =>
      KnownServices.match(input.from) == null
      ? null
      : const Classification(
          MessageCategory.notifications,
          SortingReason.knownService,
        );
}

/// `Auto-Submitted: auto-replied` (RFC 3834) is an answer to the user's
/// own mail, such as an out-of-office reply or a bounce: General (and
/// Important when it replies to a sent message), even if it carries bulk
/// headers.
final class AutoReplyRule implements SortingRule {
  const AutoReplyRule();

  @override
  Classification? apply(ClassificationInput input) =>
      input.token('auto-submitted') == 'auto-replied'
      ? const Classification(MessageCategory.general, SortingReason.autoReply)
      : null;
}

/// RFC 8058 one-click unsubscribe is used for marketing and bulk mail, so
/// it outweighs a `noreply` sender.
final class OneClickUnsubscribeRule implements SortingRule {
  const OneClickUnsubscribeRule();

  @override
  Classification? apply(ClassificationInput input) {
    final post = input.header('list-unsubscribe-post');
    // RFC 8058 requires both headers.
    final oneClick =
        post != null &&
        post.toLowerCase() == 'list-unsubscribe=one-click' &&
        input.has('list-unsubscribe');
    return oneClick
        ? const Classification(
            MessageCategory.newsletters,
            SortingReason.oneClickUnsubscribe,
          )
        : null;
  }
}

/// Machine senders (`noreply@`, `notifications@`...) and mail marked
/// `Auto-Submitted: auto-generated` or `auto-notified`.
final class AutomatedSenderRule implements SortingRule {
  const AutomatedSenderRule();

  static const _automatic = {'auto-generated', 'auto-notified'};

  @override
  Classification? apply(ClassificationInput input) =>
      AutomatedSender.matches(input.from) ||
          _automatic.contains(input.token('auto-submitted'))
      ? const Classification(
          MessageCategory.notifications,
          SortingReason.automatedSender,
        )
      : null;
}

/// Mailing lists and newsletters: `List-Id` or `List-Unsubscribe`.
final class MailingListRule implements SortingRule {
  const MailingListRule();

  @override
  Classification? apply(ClassificationInput input) =>
      input.has('list-id') || input.has('list-unsubscribe')
      ? const Classification(
          MessageCategory.newsletters,
          SortingReason.mailingList,
        )
      : null;
}

/// `Precedence: bulk`, `list` or `junk`: mass mail.
final class BulkPrecedenceRule implements SortingRule {
  const BulkPrecedenceRule();

  static const _bulk = {'bulk', 'list', 'junk'};

  @override
  Classification? apply(ClassificationInput input) =>
      _bulk.contains(input.token('precedence'))
      ? const Classification(
          MessageCategory.newsletters,
          SortingReason.bulkPrecedence,
        )
      : null;
}
