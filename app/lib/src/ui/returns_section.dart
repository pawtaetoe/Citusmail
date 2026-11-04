// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/deliveries_model.dart';
import '../mail/mail_controller.dart';
import '../services/reminders.dart' show ReminderWords;
import 'avatar.dart';
import 'subscription_detail_page.dart' show EmailPage;

/// What a return window reads as.
abstract final class ReturnText {
  /// "12 days left", "1 day left", "last day today", "closed".
  static String left(int days) => switch (days) {
    < 0 => 'closed',
    0 => 'last day today',
    1 => '1 day left',
    _ => '$days days left',
  };

  /// "Return by Fri, 4 Dec · 12 days left", "Return window closed Fri, 4
  /// Dec".
  static String deadline(ReturnWindow w, DateTime now) {
    final days = w.daysLeft(now);
    final on = ReminderWords.date(w.deadline);
    return days < 0
        ? 'Return window closed $on'
        : 'Return by $on · ${left(days)}';
  }

  /// How the deadline was found: "30 days from delivery (Sun, 1 Nov)",
  /// "15 days from the order (Mon, 2 Nov)", "Last day given by the shop".
  static String basis(ReturnWindow w) {
    final days = w.days;
    final from = w.countedFrom;
    if (w.basis == ReturnBasis.stated || days == null || from == null) {
      return 'Last day given by the shop';
    }
    final count = '$days day${days == 1 ? '' : 's'}';
    final on = ReminderWords.date(from);
    return switch (w.basis) {
      ReturnBasis.delivery => '$count from delivery ($on)',
      _ when w.fromDeliveryUnknown =>
        '$count from delivery; counted from the order ($on), as the '
            'delivery date isn\'t known',
      _ => '$count from the order ($on)',
    };
  }

  /// "AIRism Cotton T-Shirt and 2 more".
  static String? items(ReturnWindow w) => switch (w.items) {
    [] => null,
    [final one] => one,
    [final first, ...final rest] => '$first and ${rest.length} more',
  };
}

/// "Can still be returned" on the Deliveries page: orders whose mail
/// states a return window that is still open, the soonest deadline first,
/// each with "Returned" and "Keeping it" (with Undo). Those marked so can
/// be listed again from below.
final class ReturnsSection extends StatefulWidget {
  const ReturnsSection({
    super.key,
    required this.model,
    required this.controller,
    required this.now,
  });

  final DeliveriesModel model;
  final MailController controller;
  final DateTime Function() now;

  @override
  State<ReturnsSection> createState() => _ReturnsSectionState();
}

final class _ReturnsSectionState extends State<ReturnsSection> {
  bool _showDone = false;

  DeliveriesModel get _model => widget.model;

  /// The email that states the policy, read in place.
  Future<void> _open(ReturnWindow w) async {
    final message = _model.message(w.messageId);
    if (message == null) return;
    await EmailPage.open(context, widget.controller, message, title: 'Order');
  }

  void _mark(ReturnWindow w, {required bool returned}) {
    if (returned) {
      _model.markReturned(w.key);
    } else {
      _model.markKept(w.key);
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            returned
                ? 'Marked as returned'
                : 'Keeping it: ${w.shopName} won\'t be listed for returns',
          ),
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.unmarkReturn(w.key),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final open = _model.canStillReturn;
    final done = _model.doneReturns;
    if (open.isEmpty && done.isEmpty) return const SizedBox.shrink();
    final now = widget.now();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (open.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
            child: Text(
              'Can still be returned',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final w in open)
            ReturnTile(
              window: w,
              now: now,
              onOpen: () => _open(w),
              onReturned: () => _mark(w, returned: true),
              onKeep: () => _mark(w, returned: false),
            ),
        ],
        if (done.isNotEmpty) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _showDone = !_showDone),
              child: Text(
                _showDone
                    ? 'Hide the ones returned or kept'
                    : 'Show ${done.length} returned or kept',
              ),
            ),
          ),
          if (_showDone)
            for (final w in done)
              ListTile(
                key: ValueKey('return-done-${w.key}'),
                leading: Avatar(name: w.shopName, address: w.shop),
                title: Text(w.shopName),
                subtitle: Text(
                  [
                    if (_model.returned.contains(w.key))
                      'Returned'
                    else
                      'Keeping it',
                    ?ReturnText.items(w),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: () => _model.unmarkReturn(w.key),
                  child: const Text('List again'),
                ),
              ),
        ],
      ],
    );
  }
}

/// One order that can still be returned: the shop, what's in it, the
/// last day and how it was found, and "Returned" / "Keeping it".
final class ReturnTile extends StatelessWidget {
  const ReturnTile({
    super.key,
    required this.window,
    required this.now,
    required this.onOpen,
    required this.onReturned,
    required this.onKeep,
  });

  final ReturnWindow window;
  final DateTime now;
  final VoidCallback onOpen;
  final VoidCallback onReturned;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final w = window;
    final days = w.daysLeft(now);
    final soon = days <= 3;
    final items = ReturnText.items(w);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Card(
      key: ValueKey('return-${w.key}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            minVerticalPadding: 4,
            onTap: onOpen,
            leading: Avatar(name: w.shopName, address: w.shop),
            title: Text(
              w.shopName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (items != null)
                  Text(
                    items,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                Text(
                  ReturnText.deadline(w, now),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: soon ? FontWeight.w600 : null,
                  ),
                ),
                Text(ReturnText.basis(w), style: muted),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onReturned,
                  icon: const Icon(Icons.keyboard_return, size: 18),
                  label: const Text('Returned'),
                ),
                TextButton.icon(
                  onPressed: onKeep,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Keeping it'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
