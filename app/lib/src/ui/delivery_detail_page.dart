// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'avatar.dart';
import 'deliveries_page.dart' show DeliveryText;
import 'link_opener.dart';
import 'reader_pane.dart';

/// What the user chose on a delivery's page; the list carries it out and
/// offers Undo.
enum DeliveryAction { notADelivery, markDelivered, notDelivered }

/// One delivery: shop, items, carrier and tracking number, a way to the
/// carrier's tracking page, and every email about it, each opening right
/// here. Pops with a [DeliveryAction] when the user chose one.
final class DeliveryDetailPage extends StatelessWidget {
  const DeliveryDetailPage({
    super.key,
    required this.delivery,
    required this.controller,
    required this.messageById,
  });

  final Delivery delivery;
  final MailController controller;
  final StoredMessage? Function(int id) messageById;

  Future<void> _openEmail(BuildContext context, int messageId) async {
    final message = messageById(messageId);
    if (message == null) return;
    await controller.open(message);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _EmailPage(controller: controller),
      ),
    );
    // Back here: the mail screen behind shows no message.
    controller.closeMessage();
  }

  /// Opens the carrier's tracking page, after asking (the link opener
  /// shows where it goes first).
  void _track(BuildContext context, Uri url) => LinkOpener.open(
    context,
    url,
    onMailto: controller.composeTo,
    safety: controller.services.linkSafety.check,
    virusTotal: controller.services.virusTotal.enabled
        ? controller.services.virusTotal.link
        : null,
  );

  Future<void> _copy(BuildContext context, String number) async {
    await Clipboard.setData(ClipboardData(text: number));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Tracking number copied'), persist: false),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final d = delivery;
    final material = MaterialLocalizations.of(context);
    String date(DateTime t) => material.formatMediumDate(t.toLocal());
    final problem = d.status == DeliveryStatus.problem;
    final tracking = d.trackingNumber;
    final url = d.trackingUrl;

    return Scaffold(
      appBar: AppBar(title: Text(d.shopName)),
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
                            Avatar(name: d.shopName, address: d.shop, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    DeliveryText.status(context, d),
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: problem ? colors.error : null,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Last news ${date(d.lastUpdate)}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (d.probablyDelivered) ...[
                          const SizedBox(height: 12),
                          Text(
                            'No news for over a month, so it was probably '
                            'delivered.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const Divider(height: 28),
                        if (d.items.isNotEmpty)
                          _Fact(label: 'Items', value: d.items.join('\n')),
                        if (d.carrierName case final c?)
                          _Fact(label: 'Carrier', value: c),
                        if (tracking != null)
                          _Fact(
                            label: 'Tracking',
                            value: tracking,
                            trailing: IconButton(
                              tooltip: 'Copy tracking number',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.copy, size: 18),
                              onPressed: () => _copy(context, tracking),
                            ),
                            onTap: () => _copy(context, tracking),
                          ),
                        if (d.orderNumber case final o?)
                          _Fact(label: 'Order', value: o),
                        _Fact(label: 'From', value: d.shop),
                        if (url != null) ...[
                          const SizedBox(height: 14),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.tonalIcon(
                              onPressed: () => _track(context, url),
                              icon: const Icon(Icons.open_in_new, size: 18),
                              label: Text(
                                'Track on ${d.carrierName ?? url.host}',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
                  child: Text(
                    'Emails',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final (i, r) in d.records.indexed) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        ListTile(
                          key: ValueKey('delivery-email-${r.email.messageId}'),
                          leading: Icon(DeliveryText.icon(r.status)),
                          title: Text(DeliveryText.event(r.status)),
                          subtitle: Text(
                            '${date(r.email.at)} · '
                            '${r.email.subject.isEmpty ? '(no subject)' : r.email.subject}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openEmail(context, r.email.messageId),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (!d.arrived || d.probablyDelivered)
                      TextButton.icon(
                        onPressed: () => Navigator.pop(
                          context,
                          DeliveryAction.markDelivered,
                        ),
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Mark as delivered'),
                      ),
                    if (d.markedDelivered)
                      TextButton.icon(
                        onPressed: () =>
                            Navigator.pop(context, DeliveryAction.notDelivered),
                        icon: const Icon(Icons.undo, size: 18),
                        label: const Text('Not delivered yet'),
                      ),
                    TextButton.icon(
                      onPressed: () =>
                          Navigator.pop(context, DeliveryAction.notADelivery),
                      icon: const Icon(Icons.visibility_off_outlined, size: 18),
                      label: const Text('Not a delivery'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: trailing == null
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
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
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              child: Text(value, style: theme.textTheme.bodyMedium),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// An email about the delivery, read in place: Back returns to it.
final class _EmailPage extends StatefulWidget {
  const _EmailPage({required this.controller});

  final MailController controller;

  @override
  State<_EmailPage> createState() => _EmailPageState();
}

final class _EmailPageState extends State<_EmailPage> {
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

  /// Archived, deleted or closed from its own actions: back to the
  /// delivery.
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
    appBar: AppBar(title: const Text('Email')),
    body: SafeArea(
      top: false,
      child: ReaderPane(controller: widget.controller, toolbarAtBottom: true),
    ),
  );
}
