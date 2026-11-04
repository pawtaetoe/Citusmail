// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/deliveries_model.dart';
import '../mail/mail_controller.dart';
import '../services/app_services.dart';
import 'avatar.dart';
import 'citusmail_theme.dart';
import 'delivery_detail_page.dart';
import 'read_ahead.dart';
import 'returns_section.dart';

/// Shipped orders found in shop and carrier mail: what is on the way and
/// when it should arrive, then what arrived lately. Found on the device.
final class DeliveriesPage extends StatefulWidget {
  const DeliveriesPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<DeliveriesPage> createState() => _DeliveriesPageState();
}

final class _DeliveriesPageState extends State<DeliveriesPage> with ReadsAhead {
  late final DeliveriesModel _model = DeliveriesModel(
    widget.controller.services,
    now: widget.now,
  );
  bool _showOlder = false;
  bool _showHidden = false;

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

  /// The delivery's own page; "Not a delivery" and "Mark as delivered"
  /// there come back here, with Undo.
  Future<void> _select(Delivery d) async {
    _model.opened(d);
    final action = await Navigator.of(context).push<DeliveryAction>(
      MaterialPageRoute(
        builder: (_) => DeliveryDetailPage(
          delivery: d,
          controller: widget.controller,
          messageById: _model.message,
          returnWindow: _model.returnFor(d.key),
          now: widget.now,
        ),
      ),
    );
    if (action == null || !mounted) return;
    final String text;
    final VoidCallback undo;
    switch (action) {
      case DeliveryAction.notADelivery:
        _model.hide(d.key);
        text = '${d.shopName} won\'t be listed as a delivery';
        undo = () => _model.unhide(d.key);
      case DeliveryAction.markDelivered:
        _model.markDelivered(d.key);
        text = 'Marked as delivered';
        undo = () => _model.unmarkDelivered(d.key);
      case DeliveryAction.notDelivered:
        _model.unmarkDelivered(d.key);
        text = 'Back on the way';
        undo = () => _model.markDelivered(d.key);
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          persist: false,
          action: SnackBarAction(label: 'Undo', onPressed: undo),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Deliveries'),
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
          final onTheWay = _model.onTheWay;
          final delivered = _model.delivered;
          final older = _model.older;
          Widget tile(Delivery d) =>
              DeliveryTile(delivery: d, onSelect: () => _select(d));
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (_model.deliveries.isNotEmpty)
                    _Overview(
                      onTheWay: onTheWay,
                      delivered: delivered,
                      returnable: _model.canStillReturn.length,
                    )
                  else if (_model.returns.isEmpty)
                    const _Empty(),
                  if (_model.reading case final r?)
                    _Reading(
                      done: r.done,
                      total: r.total,
                      onStop: _model.stopReading,
                    )
                  else if (_model.toRead.isNotEmpty && !readsAhead)
                    _ReadOffer(
                      count: _model.toRead.length,
                      onRead: _model.readEmails,
                    )
                  else if (_model.toRead.isNotEmpty && readingAhead)
                    ReadingQuietly(
                      'Reading ${_model.toRead.length} shipping email'
                      '${_model.toRead.length == 1 ? '' : 's'}…',
                    ),
                  if (onTheWay.isNotEmpty) ...[
                    const _SectionTitle('On the way'),
                    for (final d in onTheWay) tile(d),
                  ],
                  ReturnsSection(
                    model: _model,
                    controller: widget.controller,
                    now: widget.now ?? DateTime.now,
                  ),
                  if (delivered.isNotEmpty) ...[
                    const _SectionTitle('Delivered'),
                    for (final d in delivered) tile(d),
                  ],
                  if (older.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _showOlder = !_showOlder),
                        child: Text(
                          _showOlder
                              ? 'Hide older deliveries'
                              : 'Show ${older.length} older '
                                    'deliver${older.length == 1 ? 'y' : 'ies'}',
                        ),
                      ),
                    ),
                    if (_showOlder)
                      for (final d in older) tile(d),
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
                              ? 'Hide the ones marked "not a delivery"'
                              : 'Show ${_model.hiddenOnes.length} marked "not a delivery"',
                        ),
                      ),
                    ),
                    if (_showHidden)
                      for (final d in _model.hiddenOnes)
                        ListTile(
                          leading: Avatar(name: d.shopName, address: d.shop),
                          title: Text(d.shopName),
                          subtitle: Text(
                            _model.learned.contains(d.key)
                                ? 'Left out: like ones you said aren\'t '
                                      'deliveries'
                                : d.records.last.email.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () => _model.unhide(d.key),
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

/// What a delivery's status reads as.
abstract final class DeliveryText {
  /// "Out for delivery", "Expected Thu, Nov 7", "Delivered Tue, Nov 5".
  static String status(BuildContext context, Delivery d) {
    final material = MaterialLocalizations.of(context);
    String date(DateTime t) => material.formatMediumDate(t.toLocal());
    return switch (d.status) {
      DeliveryStatus.outForDelivery => 'Out for delivery',
      DeliveryStatus.readyForPickup => 'Ready to collect',
      DeliveryStatus.problem => 'Delivery problem',
      DeliveryStatus.returned => 'Returned to sender',
      DeliveryStatus.delivered when d.probablyDelivered => 'Probably delivered',
      DeliveryStatus.delivered when d.markedDelivered => 'Marked as delivered',
      DeliveryStatus.delivered when d.deliveredAt != null =>
        'Delivered ${date(d.deliveredAt!)}',
      DeliveryStatus.delivered => 'Delivered',
      DeliveryStatus.shipped || DeliveryStatus.ordered
          when d.expected != null =>
        'Expected ${date(d.expected!)}',
      DeliveryStatus.shipped => 'On the way',
      DeliveryStatus.ordered => 'Ordered',
    };
  }

  /// One email's status: "Shipped", "Order confirmed".
  static String event(DeliveryStatus? s) => switch (s) {
    DeliveryStatus.ordered => 'Order confirmed',
    DeliveryStatus.shipped => 'Shipped',
    DeliveryStatus.readyForPickup => 'Ready to collect',
    DeliveryStatus.outForDelivery => 'Out for delivery',
    DeliveryStatus.delivered => 'Delivered',
    DeliveryStatus.problem => 'Delivery problem',
    DeliveryStatus.returned => 'Returned to sender',
    null => 'Update',
  };

  static IconData icon(DeliveryStatus? s) => switch (s) {
    DeliveryStatus.ordered => Icons.shopping_bag_outlined,
    DeliveryStatus.shipped => Icons.local_shipping_outlined,
    DeliveryStatus.readyForPickup => Icons.storefront_outlined,
    DeliveryStatus.outForDelivery => Icons.delivery_dining_outlined,
    DeliveryStatus.delivered => Icons.check_circle_outline,
    DeliveryStatus.problem => Icons.error_outline,
    DeliveryStatus.returned => Icons.keyboard_return,
    null => Icons.mail_outline,
  };

  /// "Kindle Paperwhite and 2 more".
  static String? items(Delivery d) => switch (d.items) {
    [] => null,
    [final one] => one,
    [final first, ...final rest] => '$first and ${rest.length} more',
  };
}

/// A summary: how many are on the way, out today, and arrived lately.
final class _Overview extends StatelessWidget {
  const _Overview({
    required this.onTheWay,
    required this.delivered,
    this.returnable = 0,
  });

  final List<Delivery> onTheWay;
  final List<Delivery> delivered;

  /// Orders that can still be returned.
  final int returnable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = onTheWay
        .where((d) => d.status == DeliveryStatus.outForDelivery)
        .length;
    final collect = onTheWay
        .where((d) => d.status == DeliveryStatus.readyForPickup)
        .length;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(
              Icons.local_shipping_outlined,
              size: 32,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    onTheWay.isEmpty
                        ? 'Nothing on the way'
                        : '${onTheWay.length} on the way',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (today > 0) '$today out for delivery',
                      if (collect > 0) '$collect ready to collect',
                      '${delivered.length} delivered in the last 30 days',
                      if (returnable > 0) '$returnable can still be returned',
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One delivery: the shop, what's in it, its status and carrier.
final class DeliveryTile extends StatelessWidget {
  const DeliveryTile({
    super.key,
    required this.delivery,
    required this.onSelect,
  });

  final Delivery delivery;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final d = delivery;
    final items = DeliveryText.items(d);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final problem = d.status == DeliveryStatus.problem;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('delivery-${d.key}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        onTap: onSelect,
        leading: Opacity(
          opacity: d.arrived ? 0.6 : 1,
          child: Avatar(name: d.shopName, address: d.shop),
        ),
        title: Text(
          d.shopName,
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
              [
                DeliveryText.status(context, d),
                // Not "UPS · UPS" when the carrier itself wrote.
                if (d.carrierName case final c? when c != d.shopName) c,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: problem ? muted?.copyWith(color: colors.error) : muted,
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (d.status == DeliveryStatus.outForDelivery)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: CitusPalette.citrus,
                  borderRadius: BorderRadius.circular(
                    CitusmailTheme.radiusSmall,
                  ),
                ),
                child: Text(
                  'today',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: CitusPalette.onCitrus,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else if (problem)
              Icon(Icons.error_outline, color: colors.error, size: 20),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// Offers to download shipping emails not on the device yet.
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
                const Icon(Icons.local_shipping_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Some deliveries, tracking numbers or dates may be '
                    'missing. They can be found in $count shipping '
                    'email${count == 1 ? '' : 's'} not on this device yet, '
                    'downloaded from your mail server (they stay unread).',
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onRead,
                child: const Text('Read shipping emails'),
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
                Text('Reading shipping emails: $done of $total'),
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
            Icons.local_shipping_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No deliveries found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Orders show here once shipping emails from shops or delivery '
            'companies are in your mail.',
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
      'Citusmail looks at order and shipping emails from the last year, on '
      'this device. Many shops and delivery companies add order details to '
      'their emails for mail apps to read; for the others, tracking '
      'numbers, order numbers and words such as "shipped" or "out for '
      'delivery" are read from the email. Emails with the same tracking '
      'number, or the same order number from the same shop, are one '
      'delivery.\n\n'
      'An order is listed once it ships. One with no news for a month is '
      'moved to Delivered as "probably delivered". Nothing is sent '
      'anywhere: tracking pages open only when you choose "Track", after '
      'asking. If something listed is not a delivery, open it and choose '
      '"Not a delivery".\n\n'
      'Return deadlines come from the return policy an order confirmation, '
      'receipt or delivery email states, such as "return within 30 days of '
      'delivery" or "free returns until 15 Dec". None is guessed when the '
      'email doesn\'t say. Orders marked final sale, and those returned or '
      'refunded, are left out.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}
