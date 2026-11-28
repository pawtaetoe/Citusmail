// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/detail_scaffold.dart';
import '../../inbox/state/mail_controller.dart';
import '../../reader/ui/email_page.dart';
import '../state/prices.dart';

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
  final StoredMessage? Function(MessageId id) messageById;

  Future<void> _openReceipt(BuildContext context, MessageId messageId) async {
    final message = messageById(messageId);
    if (message == null) return;
    await EmailPage.open(context, controller, message);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
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

    return DetailScaffold(
      title: s.name,
      header: DetailHeader(
        leading: Avatar(name: s.name, address: s.company, size: 44),
        title: s.amount == null
            ? 'Price unknown'
            : '${s.variable ? 'About ' : ''}'
                  '${Prices.format(s.amount!)} · '
                  '${(s.period?.label ?? Prices.cadence(s.cadence)).toLowerCase()}',
        subtitle: status,
        facts: [
          DetailFact(
            label: 'Charged',
            value: charges.isEmpty
                ? 'No receipts found'
                : '${charges.length} time${charges.length == 1 ? '' : 's'}'
                      '${firstCharge == null ? '' : ' since ${date(firstCharge)}'}',
          ),
          if (totals.isNotEmpty)
            DetailFact(
              label: 'In total',
              value:
                  '${totals.entries.map((e) => Prices.format(Money(e.value, e.key))).join(' + ')}'
                  '${totals.length == 1 && charges.any((r) => r.amount == null) ? ' (some receipts without a price)' : ''}',
            ),
          if (s.spentLastYear case final y?)
            DetailFact(
              label: 'Last year',
              value: '${Prices.format(y)} in the last 12 months',
            ),
          if (s.variable)
            const DetailFact(
              label: 'Price',
              value:
                  'Varies from charge to charge: the average of the last '
                  'ones.',
            ),
          DetailFact(label: 'From', value: s.company),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(AppIcons.hide, size: 18),
          label: const Text('Not a subscription'),
        ),
      ],
      children: [
        for (final change in changes.take(3))
          Card(
            color: colors.surfaceContainerHigh,
            child: ListTile(
              leading: Icon(change.up ? AppIcons.priceUp : AppIcons.priceDown),
              title: Text(
                'Price went ${change.up ? 'up' : 'down'} from '
                '${Prices.format(change.from)} to ${Prices.format(change.to)}',
              ),
              subtitle: Text('Receipt of ${date(change.at)}'),
            ),
          ),
        for (final MapEntry(key: year, value: records) in byYear.entries)
          DetailSection(
            title: '$year',
            children: [
              for (final r in records)
                ListTile(
                  key: ValueKey('receipt-${r.email.messageId.value}'),
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
                  trailing: const Icon(AppIcons.chevron),
                  onTap: () => _openReceipt(context, r.email.messageId),
                ),
            ],
          ),
      ],
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
    SubscriptionEvent.charge => AppIcons.bill,
    SubscriptionEvent.trial => AppIcons.trial,
    SubscriptionEvent.cancelled => AppIcons.cancelled,
    SubscriptionEvent.notice => AppIcons.mail,
  };

  static String _label(SubscriptionEvent e) => switch (e) {
    SubscriptionEvent.charge => 'Receipt (price not found)',
    SubscriptionEvent.trial => 'Trial',
    SubscriptionEvent.cancelled => 'Cancelled',
    SubscriptionEvent.notice => 'Notice',
  };
}
