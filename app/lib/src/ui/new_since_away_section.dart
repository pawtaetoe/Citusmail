// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../mail/mail_controller.dart';
import '../mail/new_since_away.dart';
import 'citusmail_theme.dart';

/// The words of "New since you were away".
abstract final class NewSinceAwayText {
  static const title = 'New since you were away';

  /// "3 emails since 9:40 AM", "1 email since yesterday".
  static String summary(BuildContext context, AwayMail mail) {
    final count = mail.messages.length;
    final emails = count == 1 ? '1 email' : '$count emails';
    final since = mail.since;
    return since == null ? emails : '$emails ${sinceWhen(context, since)}';
  }

  /// "since 9:40 AM" today, "since yesterday", else "since Nov 2".
  static String sinceWhen(BuildContext context, DateTime when) {
    final local = when.toLocal();
    final now = NewSinceAway.clock().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final localizations = MaterialLocalizations.of(context);
    if (day == today) {
      final time = localizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );
      return 'since $time';
    }
    if (today.difference(day).inDays == 1) return 'since yesterday';
    return 'since ${localizations.formatShortMonthDay(local)}';
  }

  /// "Plus 2 newsletters and 1 notification, in their sections", or null.
  static String? others(AwayMail mail) {
    String count(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
    final parts = [
      if (mail.newsletters > 0) count(mail.newsletters, 'newsletter'),
      if (mail.notifications > 0) count(mail.notifications, 'notification'),
    ];
    if (parts.isEmpty) return null;
    return 'Plus ${parts.join(' and ')}, in their sections';
  }
}

/// The header of "New since you were away": stays at the top while its
/// messages scroll, with "Mark all as read" and Done.
final class NewSinceAwayHeader extends SliverPersistentHeaderDelegate {
  NewSinceAwayHeader(this.mail, this.controller);

  final AwayMail mail;
  final MailController controller;

  static const height = 52.0;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  bool shouldRebuild(NewSinceAwayHeader old) => true;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final summary = NewSinceAwayText.summary(context, mail);
    return Material(
      color: ListColors.of(context).background,
      child: DecoratedBox(
        // A rule only while the header floats over its messages.
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: overlapsContent
                  ? colors.outlineVariant
                  : Colors.transparent,
            ),
          ),
        ),
        child: Padding(
          // Lined up with the section headers below.
          padding: const EdgeInsets.fromLTRB(22, 6, 8, 4),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Icon(
                  Icons.waving_hand_outlined,
                  size: 18,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  header: true,
                  label: '${NewSinceAwayText.title}, $summary',
                  excludeSemantics: true,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        NewSinceAwayText.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (mail.unread > 0)
                IconButton(
                  tooltip: 'Mark all as read',
                  icon: const Icon(Icons.done_all, size: 20),
                  color: colors.onSurfaceVariant,
                  onPressed: controller.markAwayRead,
                ),
              Tooltip(
                message: 'Put these back in their sections',
                child: TextButton(
                  onPressed: controller.doneWithAway,
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Under the messages of "New since you were away": "Show all", and how
/// many newsletters and notifications came too.
final class NewSinceAwayFooter extends StatelessWidget {
  const NewSinceAwayFooter({
    super.key,
    required this.mail,
    required this.hidden,
    required this.onShowAll,
  });

  final AwayMail mail;

  /// Messages not shown yet.
  final int hidden;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final others = NewSinceAwayText.others(mail);
    return Padding(
      padding: const EdgeInsets.fromLTRB(58, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hidden > 0)
            TextButton(
              onPressed: onShowAll,
              child: Text('Show all ($hidden more)'),
            ),
          if (others != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
              child: Text(
                others,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
