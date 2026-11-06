// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'mail_text.dart';
import 'subscription_detail_page.dart' show EmailPage;

/// Who read one of the user's messages, from a read receipt that came
/// back: [name] (null when it went to one person only), when, and the
/// receipt itself when it is still on the device.
final class ReadBy {
  const ReadBy({required this.name, required this.at, this.report});

  final String? name;
  final DateTime at;
  final StoredMessage? report;

  /// The read receipts of [message] that say it was displayed, oldest
  /// first, with the names it was sent to. Receipts saying it was deleted
  /// unread (or anything else) are left out: nothing is shown for them.
  static List<ReadBy> of(MailStore store, StoredMessage message) {
    final id = message.messageId;
    if (id == null) return const [];
    final read = [
      for (final r in store.receipts.forMessage(message.accountId, id))
        if (r.displayed) r,
    ];
    if (read.isEmpty) return const [];
    final recipients = [
      for (final kind in const ['to', 'cc', 'bcc'])
        ...store.messages.addresses(message.id, kind),
    ];
    final several =
        read.length > 1 ||
        {for (final a in recipients) a.address.toLowerCase()}.length > 1;
    return [
      for (final r in read)
        () {
          final reportId = store.receipts.reportFor(
            message.accountId,
            id,
            r.recipient,
          );
          final report = reportId == null
              ? null
              : store.messages.byId(reportId);
          return ReadBy(
            name: several ? _name(r.recipient, recipients, report) : null,
            at: r.at,
            report: report,
          );
        }(),
    ];
  }

  /// The name the message was sent to, else the one the receipt came
  /// from, else the address.
  static String _name(
    String address,
    List<MailAddress> recipients,
    StoredMessage? report,
  ) {
    String? named(MailAddress? a) {
      final name = a?.displayName?.trim();
      return a != null &&
              a.address.toLowerCase() == address &&
              name != null &&
              name.isNotEmpty
          ? name
          : null;
    }

    for (final a in recipients) {
      if (named(a) case final name?) return name;
    }
    return named(report?.from) ?? address;
  }
}

/// Under the header of a sent message that asked for a read receipt and
/// got one: "Read on Nov 6, 3:42 PM", or, sent to several people, one
/// "Read by Ana on …" line each. A tap opens the receipt. Shows nothing
/// until someone's mail app says it was read.
final class ReadReceiptLine extends StatelessWidget {
  const ReadReceiptLine({
    super.key,
    required this.controller,
    required this.message,
  });

  final MailController controller;
  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    if (controller.receiptsFor(message) == null) {
      return const SizedBox.shrink(); // not the user's, or didn't ask
    }
    final reads = ReadBy.of(controller.services.store, message);
    if (reads.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      // Lined up with the sender's name, beside the avatar.
      padding: const EdgeInsets.only(left: 48, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final read in reads)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: read.report == null ? null : () => _open(context, read),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.done_all, size: 16, color: muted),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _text(context, read),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _text(BuildContext context, ReadBy read) {
    final when = MailText.dayAndTime(context, read.at);
    return read.name == null
        ? 'Read on $when'
        : 'Read by ${read.name} on $when';
  }

  /// Opens the receipt on its own page; Back returns to the sent message.
  Future<void> _open(BuildContext context, ReadBy read) async {
    final report = read.report;
    if (report == null) return;
    // This line goes away once the receipt opens, so the page is pushed
    // first.
    final closed = Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            EmailPage(controller: controller, title: 'Read receipt'),
      ),
    );
    await controller.open(report);
    await closed;
    await controller.open(message);
  }
}
