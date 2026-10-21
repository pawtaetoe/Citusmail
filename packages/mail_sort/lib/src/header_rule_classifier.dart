// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import 'classification.dart';
import 'sorting_rules.dart';

/// Sorts by header rules, entirely on the device. The order matters:
///
/// | # | Rule | Category |
/// | - | ---- | -------- |
/// | 1 | Sent or Drafts folder | General |
/// | 2 | Known service (GitHub...) | Notifications |
/// | 3 | `Auto-Submitted: auto-replied` (out-of-office, bounce) | General |
/// | 4 | One-click unsubscribe (RFC 8058) | Newsletters |
/// | 5 | `noreply`-style sender, `Auto-Submitted: auto-generated` | Notifications |
/// | 6 | `List-Id` or `List-Unsubscribe` | Newsletters |
/// | 7 | `Precedence: bulk` / `list` / `junk` | Newsletters |
/// | - | anything else | General |
///
/// Pinned and Important are worked out by the store when listing the Smart
/// Inbox (see `SmartSection`), because they change as the user pins mail
/// and writes to people.
final class HeaderRuleClassifier implements MessageClassifier {
  const HeaderRuleClassifier();

  /// Bump whenever [rules] or the lists they use change, so stored mail is
  /// re-sorted (see `Resorter`).
  static const currentVersion = 1;

  static const List<SortingRule> rules = [
    OwnMailRule(),
    KnownServiceRule(),
    AutoReplyRule(),
    OneClickUnsubscribeRule(),
    AutomatedSenderRule(),
    MailingListRule(),
    BulkPrecedenceRule(),
  ];

  static const _general = Classification(
    MessageCategory.general,
    SortingReason.noSignal,
  );

  @override
  int get version => currentVersion;

  @override
  Classification classify(ClassificationInput input) {
    for (final rule in rules) {
      final decision = rule.apply(input);
      if (decision != null) return decision;
    }
    return _general;
  }
}
