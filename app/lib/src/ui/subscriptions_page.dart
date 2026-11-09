// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/mail_controller.dart';
import '../mail/subscriptions_model.dart';
import '../services/app_services.dart';
import '../services/reminders.dart';
import 'app_icons.dart';
import 'avatar.dart';
import 'badge.dart';
import 'page_scaffold.dart';
import 'read_ahead.dart';
import 'skeleton_rows.dart';
import 'subscription_detail_page.dart';

/// Paid subscriptions found in the user's receipts and renewal mail: what
/// each costs, how often, and when it charges next; and what is coming up
/// (bills due, free trials ending, renewals). Found on the device.
final class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<SubscriptionsPage> createState() => _SubscriptionsPageState();
}

final class _SubscriptionsPageState extends State<SubscriptionsPage>
    with ReadsAhead {
  late final SubscriptionsModel _model = SubscriptionsModel(
    widget.controller.services,
    now: widget.now,
  );
  bool _showHidden = false;

  DateTime get _today => (widget.now ?? DateTime.now)();

  @override
  AppServices get services => widget.controller.services;

  @override
  Future<void> reload() => _model.load();

  @override
  void initState() {
    super.initState();
    _model.load().then((_) => loadedWith(_model.toRead));
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
    _model.opened(s);
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

  /// The bill, trial email or last receipt, read in place.
  Future<void> _openReminder(Reminder r) async {
    final message = _model.message(r.messageId);
    if (message == null) return;
    await EmailPage.open(
      context,
      widget.controller,
      message,
      title: switch (r.kind) {
        ReminderKind.billDue => 'Bill',
        ReminderKind.trialEnds => 'Free trial',
        ReminderKind.renewal => 'Receipt',
        ReminderKind.returnBy => 'Order',
        ReminderKind.appointment => 'Appointment',
      },
    );
  }

  /// "Done" or "Not needed": gone from the list, with Undo.
  void _dismiss(Reminder r) {
    _model.dismiss(r);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${r.name} removed from Coming up'),
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.undismiss(r),
          ),
        ),
      );
  }

  void _hide(Subscription s) {
    _model.hide(s.company);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${s.name} won\'t be listed as a subscription'),
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.unhide(s.company),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'Subscriptions',
    help: (
      tooltip: 'How is this found?',
      onPressed: () => _HowDialog.show(context),
    ),

    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: _model,
        builder: (context, _) {
          if (_model.loading) {
            return const SkeletonRows(
              label: 'Finding subscriptions…',
              maxWidth: PageScaffold.width,
            );
          }
          final all = _model.subscriptions;
          final soon = _model.renewingSoon.toSet();
          final comingUp = _model.comingUp;
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
                  // What needs doing soon, first.
                  if (comingUp.isNotEmpty) ...[
                    const _SectionTitle('Coming up', top: 8),
                    for (final r in comingUp)
                      _ReminderTile(
                        reminder: r,
                        now: _today,
                        onOpen: () => _openReminder(r),
                        onDismiss: () => _dismiss(r),
                      ),
                  ],
                  if (all.isEmpty && comingUp.isEmpty)
                    const _Empty()
                  else if (all.isNotEmpty)
                    _Overview(
                      model: _model,
                      soon: soon.length,
                      onSelect: _select,
                    ),
                  if (_model.reading case final r?)
                    _Reading(
                      done: r.done,
                      total: r.total,
                      onStop: _model.stopReading,
                    )
                  else if (_model.toRead.isNotEmpty && !readsAhead)
                    _ReadOffer(
                      count: _model.toRead.length,
                      onRead: _model.readReceipts,
                    )
                  else if (_model.toRead.isNotEmpty && readingAhead)
                    ReadingQuietly(
                      'Reading ${_model.toRead.length} receipt'
                      '${_model.toRead.length == 1 ? '' : 's'}…',
                    ),
                  if (active.isNotEmpty) ...[
                    const _SectionTitle('Active'),
                    // Renewing within a week first.
                    for (final s in [
                      ...active.where(soon.contains),
                      ...active.where((s) => !soon.contains(s)),
                    ])
                      _SubscriptionTile(
                        subscription: s,
                        today: _today,
                        soon: soon.contains(s),
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
                          subtitle: Text(
                            _model.learned.contains(s.company)
                                ? 'Left out: like ones you said aren\'t '
                                      'subscriptions'
                                : s.company,
                          ),
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

/// The overview: what the active subscriptions cost a year, a month and
/// a day, and how the year splits between them (one bar per currency;
/// prices are never converted).
final class _Overview extends StatelessWidget {
  const _Overview({
    required this.model,
    required this.soon,
    required this.onSelect,
  });

  final SubscriptionsModel model;
  final int soon;
  final void Function(Subscription) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final active = model.active;
    final unpriced = active.where((s) => s.yearly == null).length;
    // Per currency, the biggest spend first.
    final byCurrency = <String, List<Subscription>>{};
    for (final s in active) {
      if (s.yearly case final y?) {
        byCurrency.putIfAbsent(y.currency, () => []).add(s);
      }
    }
    int total(List<Subscription> list) =>
        list.fold(0, (sum, s) => sum + s.yearly!.minor);
    final currencies = byCurrency.keys.toList()
      ..sort((a, b) => total(byCurrency[b]!).compareTo(total(byCurrency[a]!)));

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your subscriptions', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
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
            for (final (i, currency) in currencies.indexed) ...[
              if (i > 0)
                const Divider(height: 32)
              else
                const SizedBox(height: 18),
              _Spend(
                yearly: Money(total(byCurrency[currency]!), currency),
                subscriptions: byCurrency[currency]!,
                onSelect: onSelect,
              ),
            ],
            if (currencies.length > 1) ...[
              const SizedBox(height: 12),
              Text(
                'Prices in different currencies are added up separately.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One currency's spend: per year, month and day, and the split.
final class _Spend extends StatelessWidget {
  const _Spend({
    required this.yearly,
    required this.subscriptions,
    required this.onSelect,
  });

  final Money yearly;
  final List<Subscription> subscriptions;
  final void Function(Subscription) onSelect;

  /// Categorical colours in a fixed order (checked for colour blindness
  /// against each mode's surface); a sixth and later go into "Others".
  static const _light = [
    Color(0xFF00927A),
    Color(0xFFE0A030),
    Color(0xFF4F6FD0),
    Color(0xFFD0604A),
    Color(0xFF9A62C0),
  ];
  static const _dark = [
    Color(0xFF14957D),
    Color(0xFFBA7A12),
    Color(0xFF5A7BD0),
    Color(0xFFC9604D),
    Color(0xFF9A6BC0),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = theme.brightness == Brightness.dark ? _dark : _light;
    final c = yearly.currency;
    final sorted = [...subscriptions]
      ..sort((a, b) => b.yearly!.minor.compareTo(a.yearly!.minor));
    final shown = sorted.length > palette.length
        ? sorted.take(palette.length - 1).toList()
        : sorted;
    final others = sorted.skip(shown.length).toList();
    final parts = <({String name, int minor, Color color, Subscription? s})>[
      for (final (i, s) in shown.indexed)
        (name: s.name, minor: s.yearly!.minor, color: palette[i], s: s),
      if (others.isNotEmpty)
        (
          name: '${others.length} others',
          minor: others.fold(0, (sum, s) => sum + s.yearly!.minor),
          color: colors.outline,
          s: null,
        ),
    ];
    String pct(int minor) {
      final p = minor * 100 / yearly.minor;
      return p < 1 ? '<1%' : '${p.round()}%';
    }

    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 4,
              child: _Figure(
                label: 'Per year',
                value: Prices.format(yearly),
                big: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: _Figure(
                label: 'Per month',
                value: Prices.format(Money((yearly.minor / 12).round(), c)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: _Figure(
                label: 'Per day',
                value: Prices.format(Money((yearly.minor / 365).round(), c)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // The split: one bar, a 2px gap between parts.
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 14,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, part) in parts.indexed) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Expanded(
                    flex: part.minor < 1 ? 1 : part.minor,
                    child: Tooltip(
                      message:
                          '${part.name}: ${Prices.format(Money(part.minor, c))} '
                          'a year (${pct(part.minor)})',
                      child: ColoredBox(color: part.color),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final part in parts)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: part.s == null ? null : () => onSelect(part.s!),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: part.color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      part.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${Prices.format(Money(part.minor, c))} a year',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      pct(part.minor),
                      textAlign: TextAlign.end,
                      style: muted?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A labelled number: "Per month / S$29.96".
final class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.big = false});

  final String label;
  final String value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        // Shrinks rather than wraps when a price is long.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style:
                (big
                        ? theme.textTheme.headlineSmall
                        : theme.textTheme.titleLarge)
                    ?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
          ),
        ),
      ],
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
                    'Some subscriptions, prices or dates may be missing. '
                    'They can be found in $count receipt${count == 1 ? '' : 's'} '
                    'not on this device yet, downloaded from your mail server '
                    '(they stay unread).',
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
  const _SectionTitle(this.text, {this.top = 20});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(4, top, 4, 8),
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
        SubscriptionStatus.active => 'Active',
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
                  s.amount == null
                      ? '—'
                      : '${s.variable ? '~' : ''}${Prices.format(s.amount!)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: ended ? colors.onSurfaceVariant : null,
                  ),
                ),
                if (soon && days != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: AppBadge(
                      days <= 0
                          ? 'today'
                          : days == 1
                          ? 'tomorrow'
                          : 'in $days days',
                      tone: BadgeTone.accent,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 4),
            const Icon(AppIcons.chevron),
          ],
        ),
      ),
    );
  }
}

/// A bill due, a free trial ending or a renewal: the date, the amount, and
/// "Done" / "Not needed". Opens its email.
final class _ReminderTile extends StatelessWidget {
  const _ReminderTile({
    required this.reminder,
    required this.now,
    required this.onOpen,
    required this.onDismiss,
  });

  final Reminder reminder;
  final DateTime now;
  final VoidCallback onOpen;

  /// "Done" or "Not needed": no longer shown or notified.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final r = reminder;
    final days = r.daysFrom(now);
    final amount = r.amount;
    final (IconData icon, String what) = switch (r.kind) {
      ReminderKind.billDue => (Icons.receipt_long_outlined, 'Bill'),
      ReminderKind.trialEnds => (AppIcons.noReply, 'Free trial'),
      ReminderKind.renewal => (AppIcons.subscriptions, 'Renewal'),
      ReminderKind.returnBy => (Icons.keyboard_return, 'Return'),
      ReminderKind.appointment => (Icons.event_outlined, 'Appointment'),
    };
    final overdue = days < 0;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('reminder-${r.key}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 0, 6),
        onTap: onOpen,
        leading: Avatar(name: r.name, address: r.company),
        title: Text(
          r.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text.rich(
          TextSpan(
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    icon,
                    size: 14,
                    color: colors.onSurfaceVariant,
                    semanticLabel: what,
                  ),
                ),
              ),
              TextSpan(text: ReminderWords.detail(r, now)),
            ],
          ),
          style: theme.textTheme.bodySmall?.copyWith(
            color: overdue ? colors.error : colors.onSurfaceVariant,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // A trial's price is in its line; it costs nothing yet.
                if (amount != null && r.kind != ReminderKind.trialEnds)
                  Text(
                    Prices.format(amount),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppBadge(
                    ReminderWords.when(days),
                    tone: overdue
                        ? BadgeTone.danger
                        : days <= 3
                        ? BadgeTone.accent
                        : BadgeTone.neutral,
                  ),
                ),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: 'Done or not needed',
              onSelected: (_) => onDismiss(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'Done',
                  child: Text(
                    r.kind == ReminderKind.billDue
                        ? 'Done, it\'s paid'
                        : 'Done',
                  ),
                ),
                const PopupMenuItem(
                  value: 'Not needed',
                  child: Text('Not needed'),
                ),
              ],
            ),
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
            AppIcons.subscriptions,
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
      'Citusmail looks at receipts, invoices, bills and renewal emails from '
      'the last two years, on this device. A company is listed once it has '
      'charged you, and when its mail speaks of a subscription, membership, '
      'renewal or billing period, or it charged you at a regular interval at '
      'least three times. A free trial shows once it charges; one-off '
      'orders and account statements are left out.\n\n'
      'Prices, how often you pay and the next charge are read from those '
      'emails, so they are estimates: check the receipt when it matters. '
      'Nothing is sent anywhere. If something listed is not a subscription, '
      'open it and choose "Not a subscription".\n\n'
      'Coming up lists bills that say when they are due (until a payment '
      'to the same company arrives), free trials that say when they end, '
      'and yearly subscriptions renewing within a week. Choose "Done" or '
      '"Not needed" to remove one.',
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
