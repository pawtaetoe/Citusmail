// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/mail_controller.dart';
import '../mail/subscriptions_model.dart';
import 'avatar.dart';
import 'citusmail_theme.dart';
import 'subscription_detail_page.dart';

/// Paid subscriptions found in the user's receipts and renewal mail: what
/// each costs, how often, and when it charges next. Found on the device.
final class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

final class _SubscriptionsPageState extends State<SubscriptionsPage> {
  late final SubscriptionsModel _model = SubscriptionsModel(
    widget.controller.services,
    now: widget.now,
  );
  bool _showHidden = false;

  DateTime get _today => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _model.load();
  }

  @override
  void dispose() {
    _model.stopReading();
    _model.dispose();
    super.dispose();
  }

  /// The subscription's own page; "Not a subscription" there comes back
  /// here, with Undo.
  Future<void> _select(Subscription s) async {
    final notOne = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubscriptionDetailPage(
          subscription: s,
          controller: widget.controller,
          messageById: _model.message,
        ),
      ),
    );
    if (notOne == true && mounted) _hide(s);
  }

  void _hide(Subscription s) {
    _model.hide(s.company);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${s.name} won\'t be listed as a subscription'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.unhide(s.company),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Subscriptions'),
      actions: [
        IconButton(
          tooltip: 'How is this found?',
          icon: const Icon(Icons.help_outline),
          onPressed: () => _HowDialog.show(context),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: _model,
        builder: (context, _) {
          if (_model.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = _model.subscriptions;
          final soon = _model.renewingSoon.toSet();
          final active = [
            for (final s in all)
              if (s.status == SubscriptionStatus.active) s,
          ];
          final ended = [
            for (final s in all)
              if (s.status != SubscriptionStatus.active) s,
          ];
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (all.isEmpty)
                    const _Empty()
                  else
                    _Summary(model: _model, soon: soon.length),
                  if (_model.reading case final r?)
                    _Reading(
                      done: r.done,
                      total: r.total,
                      onStop: _model.stopReading,
                    )
                  else if (_model.toRead.isNotEmpty)
                    _ReadOffer(
                      count: _model.toRead.length,
                      onRead: _model.readReceipts,
                    ),
                  if (soon.isNotEmpty) ...[
                    const _SectionTitle('Renewing soon'),
                    for (final s in active.where(soon.contains))
                      _SubscriptionTile(
                        subscription: s,
                        today: _today,
                        soon: true,
                        onSelect: () => _select(s),
                      ),
                  ],
                  if (active.any((s) => !soon.contains(s))) ...[
                    _SectionTitle(soon.isEmpty ? 'Active' : 'Other active'),
                    for (final s in active.where((s) => !soon.contains(s)))
                      _SubscriptionTile(
                        subscription: s,
                        today: _today,
                        onSelect: () => _select(s),
                      ),
                  ],
                  if (ended.isNotEmpty) ...[
                    const _SectionTitle('Ended or cancelled'),
                    for (final s in ended)
                      _SubscriptionTile(
                        subscription: s,
                        today: _today,
                        onSelect: () => _select(s),
                      ),
                  ],
                  if (_model.hiddenOnes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _showHidden = !_showHidden),
                        child: Text(
                          _showHidden
                              ? 'Hide the ones marked "not a subscription"'
                              : 'Show ${_model.hiddenOnes.length} marked "not a subscription"',
                        ),
                      ),
                    ),
                    if (_showHidden)
                      for (final s in _model.hiddenOnes)
                        ListTile(
                          leading: Avatar(name: s.name, address: s.company),
                          title: Text(s.name),
                          subtitle: Text(s.company),
                          trailing: TextButton(
                            onPressed: () => _model.unhide(s.company),
                            child: const Text('List again'),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// "About S$46.95 a month · 5 active".
final class _Summary extends StatelessWidget {
  const _Summary({required this.model, required this.soon});

  final SubscriptionsModel model;
  final int soon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final totals = model.monthlyTotals;
    final active = model.active;
    final unpriced = active.where((s) => s.monthly == null).length;
    final total = totals.isEmpty
        ? null
        : totals.entries
              .map((e) => Prices.format(Money(e.value, e.key)))
              .join(' + ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              total == null ? 'Your subscriptions' : 'About $total a month',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              [
                '${active.length} active',
                if (soon > 0) '$soon renewing within a week',
                if (unpriced > 0) '$unpriced without a known price',
              ].join(' · '),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offers to download the receipts whose prices are not known yet.
final class _ReadOffer extends StatelessWidget {
  const _ReadOffer({required this.count, required this.onRead});

  final int count;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.receipt_long_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Some prices or dates are missing. They can be found in '
                    '$count receipt${count == 1 ? '' : 's'} not on this device '
                    'yet, downloaded from your mail server (they stay unread).',
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onRead,
                child: const Text('Read receipts'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Reading extends StatelessWidget {
  const _Reading({
    required this.done,
    required this.total,
    required this.onStop,
  });

  final int done;
  final int total;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reading receipts: $done of $total'),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: onStop, child: const Text('Stop')),
        ],
      ),
    ),
  );
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// One subscription: name, cadence and next charge, price; opens to its
/// receipts.
final class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.subscription,
    required this.today,
    required this.onSelect,
    this.soon = false,
  });

  final Subscription subscription;
  final DateTime today;

  /// Opens the subscription's page (its receipts).
  final VoidCallback onSelect;
  final bool soon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final s = subscription;
    final ended = s.status != SubscriptionStatus.active;
    final material = MaterialLocalizations.of(context);
    String date(DateTime d) => material.formatMediumDate(d.toLocal());

    final details = <String>[
      Prices.cadence(s.cadence),
      switch (s.status) {
        SubscriptionStatus.cancelled => 'Cancelled',
        SubscriptionStatus.lapsed when s.lastCharge != null =>
          'Last charged ${date(s.lastCharge!)}',
        SubscriptionStatus.lapsed => 'Probably ended',
        SubscriptionStatus.active when s.nextCharge != null =>
          'Next charge about ${date(s.nextCharge!)}',
        SubscriptionStatus.active when s.lastCharge != null =>
          'Last charged ${date(s.lastCharge!)}',
        SubscriptionStatus.active => 'Trial',
      },
    ];
    final days = s.nextCharge?.difference(today).inDays;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('subscription-${s.company}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        onTap: onSelect,
        leading: Opacity(
          opacity: ended ? 0.6 : 1,
          child: Avatar(name: s.name, address: s.company),
        ),
        title: Text(
          s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          details.join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  s.amount == null ? '—' : Prices.format(s.amount!),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: ended ? colors.onSurfaceVariant : null,
                  ),
                ),
                if (soon && days != null)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: CitusPalette.citrus,
                      borderRadius: BorderRadius.circular(
                        CitusmailTheme.radiusSmall,
                      ),
                    ),
                    child: Text(
                      days <= 0
                          ? 'today'
                          : days == 1
                          ? 'tomorrow'
                          : 'in $days days',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: CitusPalette.onCitrus,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

final class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        children: [
          Icon(
            Icons.autorenew,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No subscriptions found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Subscriptions show here once receipts or renewal emails for them '
            'are in your mail.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

final class _HowDialog extends StatelessWidget {
  const _HowDialog();

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const _HowDialog());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How is this found?'),
    content: const Text(
      'Citusmail looks at receipts, invoices and renewal emails from the '
      'last two years, on this device. A company is listed when its mail '
      'speaks of a subscription, membership or renewal, or when it charged '
      'you at a regular interval at least three times.\n\n'
      'Prices, how often you pay and the next charge are read from those '
      'emails, so they are estimates: check the receipt when it matters. '
      'Nothing is sent anywhere. If something listed is not a subscription, '
      'open it and choose "Not a subscription".',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}

/// Prices and cadences in words.
abstract final class Prices {
  static const _symbols = {
    'SGD': r'S$',
    'USD': r'US$',
    'AUD': r'A$',
    'CAD': r'C$',
    'HKD': r'HK$',
    'NZD': r'NZ$',
    'EUR': '€',
    'GBP': '£',
    'JPY': '¥',
    'INR': '₹',
    'KRW': '₩',
    'MYR': 'RM',
    r'$': r'$',
  };

  /// "S$17.98", "¥1200", "CHF 9.90".
  static String format(Money money) {
    final noCents = money.currency == 'JPY' || money.currency == 'KRW';
    final units = money.minor ~/ 100;
    final cents = (money.minor % 100).toString().padLeft(2, '0');
    final grouped = units.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final number = noCents ? grouped : '$grouped.$cents';
    final symbol = _symbols[money.currency];
    return symbol == null ? '${money.currency} $number' : '$symbol$number';
  }

  static String cadence(Cadence? cadence) => switch (cadence) {
    Cadence.weekly => 'Weekly',
    Cadence.monthly => 'Monthly',
    Cadence.quarterly => 'Every 3 months',
    Cadence.yearly => 'Yearly',
    null => 'How often unknown',
  };
}
