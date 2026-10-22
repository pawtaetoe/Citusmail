// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

/// User-facing names, icons and dates for mail, in one place.
abstract final class MailText {
  /// The colour of pins everywhere.
  static const pinColor = Color(0xFFE5484D);

  static String section(SmartSection section) => switch (section) {
    SmartSection.pinned => 'Pinned',
    SmartSection.important => 'Important',
    SmartSection.general => 'General',
    SmartSection.notifications => 'Notifications',
    SmartSection.newsletters => 'Newsletters',
  };

  static IconData sectionIcon(SmartSection section) => switch (section) {
    SmartSection.pinned => Icons.push_pin,
    SmartSection.important => Icons.label_important_outline,
    SmartSection.general => Icons.mail_outline,
    SmartSection.notifications => Icons.notifications_none,
    SmartSection.newsletters => Icons.rss_feed,
  };

  static Color sectionColor(SmartSection section, ColorScheme colors) =>
      switch (section) {
        SmartSection.pinned => pinColor,
        SmartSection.important => const Color(0xFFF5A524),
        SmartSection.general => colors.primary,
        SmartSection.notifications => const Color(0xFF30A46C),
        SmartSection.newsletters => const Color(0xFFF76B15),
      };

  /// A folder's name in the sidebar: standard folders get standard names,
  /// whatever the server calls them.
  static String folder(StoredMailbox mailbox) => mailbox.isInbox
      ? 'Inbox'
      : switch (mailbox.specialUse) {
          SpecialUse.sent => 'Sent',
          SpecialUse.drafts => 'Drafts',
          SpecialUse.archive => 'Archive',
          SpecialUse.trash => 'Trash',
          SpecialUse.junk => 'Spam',
          SpecialUse.all => 'All Mail',
          SpecialUse.flagged => 'Starred',
          SpecialUse.important => 'Important',
          null => _lastSegment(mailbox),
        };

  static IconData folderIcon(StoredMailbox mailbox) => mailbox.isInbox
      ? Icons.inbox_outlined
      : switch (mailbox.specialUse) {
          SpecialUse.sent => Icons.send_outlined,
          SpecialUse.drafts => Icons.edit_note,
          SpecialUse.archive => Icons.archive_outlined,
          SpecialUse.trash => Icons.delete_outline,
          SpecialUse.junk => Icons.report_gmailerrorred,
          SpecialUse.all => Icons.all_inbox_outlined,
          SpecialUse.flagged => Icons.star_outline,
          SpecialUse.important => Icons.label_important_outline,
          null => Icons.folder_outlined,
        };

  /// `INBOX.Projects.2026` -> `2026` (the tree shows the rest).
  static String _lastSegment(StoredMailbox mailbox) {
    final delimiter = mailbox.delimiter;
    if (delimiter == null || delimiter.isEmpty) return mailbox.name;
    return mailbox.name.split(delimiter).last;
  }

  /// Who a message is from, for lists.
  static String sender(StoredMessage message) {
    final from = message.from;
    if (from == null) return '(no sender)';
    final name = from.displayName?.trim();
    return name == null || name.isEmpty ? from.address : name;
  }

  static String subject(StoredMessage message) {
    final subject = message.subject?.trim();
    return subject == null || subject.isEmpty ? '(no subject)' : subject;
  }

  static String address(MailAddress address) {
    final name = address.displayName?.trim();
    return name == null || name.isEmpty
        ? address.address
        : '$name <${address.address}>';
  }

  /// Time today, "Yesterday", day and month this year, else a full date.
  static String listDate(BuildContext context, DateTime when) {
    final local = when.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final localizations = MaterialLocalizations.of(context);
    if (day == today) {
      return localizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );
    }
    if (today.difference(day).inDays == 1) return 'Yesterday';
    if (local.year == now.year) return localizations.formatShortMonthDay(local);
    return localizations.formatShortDate(local);
  }

  /// The date in the reading pane: weekday, date and time.
  static String fullDate(BuildContext context, DateTime when) {
    final local = when.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return '${localizations.formatFullDate(local)}, $time';
  }

  static String size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
