// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'avatar.dart';
import 'reader_pane.dart';
import 'subscriptions_page.dart' show Prices;

/// One subscription: what it costs now, what it cost over time, and every
/// receipt found, each opening right here. Pops with `true` when the user
/// says it is not a subscription (the list then offers Undo).
final class SubscriptionDetailPage extends StatelessWidget {
  const SubscriptionDetailPage({
    super.key,
    required this.subscription,
    required this.controller,
    required this.messageById,
  });

  final Subscription subscription;
  final MailController controller;
  final StoredMessage? Function(int id) messageById;

  Future<void> _openReceipt(BuildContext context, int messageId) async {
    final message = messageById(messageId);
    if (message == null) return;
    await EmailPage.open(context, controller, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final s = subscription;
    final material = MaterialLocalizations.of(context);
    String date(DateTime d) => material.formatMediumDate(d.toLocal());

    final charges = [
      for (final r in s.records)
        if (r.event == SubscriptionEvent.charge) r,
    ];
    final totals = <String, int>{};
    for (final r in charges) {
      if (r.amount case final a?) {
        totals[a.currency] = (totals[a.currency] ?? 0) + a.minor;
      }
    }
    // A bill that varies every month has no "price changes".
    final changes = s.variable
        ? const <({Money from, Money to, DateTime at, bool up})>[]
        : _priceChanges(charges);
    final firstCharge = charges.lastOrNull?.email.at;

    final status = switch (s.status) {
      SubscriptionStatus.cancelled => 'Cancelled',
      SubscriptionStatus.lapsed => 'Probably ended',
      SubscriptionStatus.active when s.nextCharge != null =>
        'Next charge about ${date(s.nextCharge!)}',
      SubscriptionStatus.active => 'Active',
    };

    // Receipts by year, newest first.
    final byYear = <int, List<SubscriptionRecord>>{};
    for (final r in s.records) {
      byYear.putIfAbsent(r.email.at.toLocal().year, () => []).add(r);
    }

    return Scaffold(
      appBar: AppBar(title: Text(s.name)),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Avatar(name: s.name, address: s.company, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.amount == null
                                        ? 'Price unknown'
                                        : '${s.variable ? 'About ' : ''}'
                                              '${Prices.format(s.amount!)} · '
                                              '${Prices.cadence(s.cadence).toLowerCase()}',
                                    style: theme.textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    status,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 28),
                        _Fact(
                          label: 'Charged',
                          value: charges.isEmpty
                              ? 'No receipts found'
                              : '${charges.length} time${charges.length == 1 ? '' : 's'}'
                                    '${firstCharge == null ? '' : ' since ${date(firstCharge)}'}',
                        ),
                        if (totals.isNotEmpty)
                          _Fact(
                            label: 'In total',
                            value:
                                '${totals.entries.map((e) => Prices.format(Money(e.value, e.key))).join(' + ')}'
                                '${totals.length == 1 && charges.any((r) => r.amount == null) ? ' (some receipts without a price)' : ''}',
                          ),
                        if (s.spentLastYear case final y?)
                          _Fact(
                            label: 'Last year',
                            value: '${Prices.format(y)} in the last 12 months',
                          ),
                        if (s.variable)
                          const _Fact(
                            label: 'Price',
                            value:
                                'Varies from charge to charge: the average of '
                                'the last ones.',
                          ),
                        _Fact(label: 'From', value: s.company),
                      ],
                    ),
                  ),
                ),
                for (final change in changes.take(3))
                  Card(
                    color: colors.surfaceContainerHigh,
                    child: ListTile(
                      leading: Icon(
                        change.up ? Icons.trending_up : Icons.trending_down,
                      ),
                      title: Text(
                        'Price went ${change.up ? 'up' : 'down'} from '
                        '${Prices.format(change.from)} to ${Prices.format(change.to)}',
                      ),
                      subtitle: Text('Receipt of ${date(change.at)}'),
                    ),
                  ),
                for (final MapEntry(key: year, value: records)
                    in byYear.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
                    child: Text(
                      '$year',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final (i, r) in records.indexed) ...[
                          if (i > 0) const Divider(height: 1, indent: 56),
                          ListTile(
                            key: ValueKey('receipt-${r.email.messageId}'),
                            leading: Icon(_icon(r.event)),
                            title: Text(
                              r.amount != null
                                  ? Prices.format(r.amount!)
                                  : _label(r.event),
                              style: const TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            subtitle: Text(
                              '${date(r.email.at)} · '
                              '${r.email.subject.isEmpty ? '(no subject)' : r.email.subject}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                _openReceipt(context, r.email.messageId),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: const Text('Not a subscription'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Price changes between charges in the same currency, newest first.
  static List<({Money from, Money to, DateTime at, bool up})> _priceChanges(
    List<SubscriptionRecord> charges,
  ) {
    final changes = <({Money from, Money to, DateTime at, bool up})>[];
    Money? previous;
    for (final r in charges.reversed) {
      final a = r.amount;
      if (a == null) continue;
      if (previous != null &&
          previous.currency == a.currency &&
          previous.minor != a.minor) {
        changes.add((
          from: previous,
          to: a,
          at: r.email.at,
          up: a.minor > previous.minor,
        ));
      }
      previous = a;
    }
    return changes.reversed.toList();
  }

  static IconData _icon(SubscriptionEvent e) => switch (e) {
    SubscriptionEvent.charge => Icons.receipt_long_outlined,
    SubscriptionEvent.trial => Icons.hourglass_top,
    SubscriptionEvent.cancelled => Icons.cancel_outlined,
    SubscriptionEvent.notice => Icons.mail_outline,
  };

  static String _label(SubscriptionEvent e) => switch (e) {
    SubscriptionEvent.charge => 'Receipt (price not found)',
    SubscriptionEvent.trial => 'Trial',
    SubscriptionEvent.cancelled => 'Cancelled',
    SubscriptionEvent.notice => 'Notice',
  };
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// A receipt or a bill, read in place: Back returns to where it was
/// opened from.
final class EmailPage extends StatefulWidget {
  const EmailPage({
    super.key,
    required this.controller,
    this.title = 'Receipt',
  });

  final MailController controller;
  final String title;

  /// Opens [message] on its own page; when it closes, the mail screen
  /// behind shows no message.
  static Future<void> open(
    BuildContext context,
    MailController controller,
    StoredMessage message, {
    String title = 'Receipt',
  }) async {
    await controller.open(message);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmailPage(controller: controller, title: title),
      ),
    );
    controller.closeMessage();
  }

  @override
  State<EmailPage> createState() => _EmailPageState();
}

final class _EmailPageState extends State<EmailPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.reader.addListener(_closedElsewhere);
  }

  @override
  void dispose() {
    widget.controller.reader.removeListener(_closedElsewhere);
    super.dispose();
  }

  /// Archived, deleted or closed from its own actions: back to the list.
  void _closedElsewhere() {
    // Only while this page is on top: going back closes the message too.
    if (widget.controller.reader.value.message == null &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      top: false,
      child: ReaderPane(controller: widget.controller, toolbarAtBottom: true),
    ),
  );
}
