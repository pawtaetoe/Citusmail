// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_extract/mail_extract.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/detail_scaffold.dart';
import '../../inbox/state/mail_controller.dart';
import '../../reader/ui/email_page.dart';
import '../../reader/ui/link_opener.dart';
import 'deliveries_page.dart' show DeliveryText;
import 'returns_section.dart' show ReturnText;

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
    this.returnWindow,
    this.now,
  });

  final Delivery delivery;
  final MailController controller;
  final StoredMessage? Function(MessageId id) messageById;

  /// Its return window, when its mail states one.
  final ReturnWindow? returnWindow;

  /// Today (tests).
  final DateTime Function()? now;

  Future<void> _openEmail(BuildContext context, MessageId messageId) async {
    final message = messageById(messageId);
    if (message == null) return;
    await EmailPage.open(context, controller, message, title: 'Email');
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
    final colors = Theme.of(context).colorScheme;
    final d = delivery;
    final material = MaterialLocalizations.of(context);
    String date(DateTime t) => material.formatMediumDate(t.toLocal());
    final problem = d.status == DeliveryStatus.problem;
    final tracking = d.trackingNumber;
    final url = d.trackingUrl;

    return DetailScaffold(
      title: d.shopName,
      header: DetailHeader(
        leading: Avatar(name: d.shopName, address: d.shop, size: 44),
        title: DeliveryText.status(context, d),
        titleColor: problem ? colors.error : null,
        subtitle: 'Last news ${date(d.lastUpdate)}',
        notes: [
          if (d.probablyDelivered)
            'No news for over a month, so it was probably delivered.',
        ],
        facts: [
          if (d.items.isNotEmpty)
            DetailFact(label: 'Items', value: d.items.join('\n')),
          if (d.carrierName case final c?)
            DetailFact(label: 'Carrier', value: c),
          if (tracking != null)
            DetailFact(
              label: 'Tracking',
              value: tracking,
              trailing: IconButton(
                tooltip: 'Copy tracking number',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.copy, size: 18),
                onPressed: () => _copy(context, tracking),
              ),
              onTap: () => _copy(context, tracking),
            ),
          if (d.orderNumber case final o?) DetailFact(label: 'Order', value: o),
          DetailFact(label: 'From', value: d.shop),
          if (returnWindow case final w?)
            DetailFact(
              label: 'Returns',
              value:
                  '${ReturnText.deadline(w, (now ?? DateTime.now)())}'
                  '\n${ReturnText.basis(w)}',
            ),
        ],
        footer: [
          if (url != null) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => _track(context, url),
                icon: const Icon(AppIcons.openExternal, size: 18),
                label: Text('Track on ${d.carrierName ?? url.host}'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (!d.arrived || d.probablyDelivered)
          TextButton.icon(
            onPressed: () =>
                Navigator.pop(context, DeliveryAction.markDelivered),
            icon: const Icon(AppIcons.done, size: 18),
            label: const Text('Mark as delivered'),
          ),
        if (d.markedDelivered)
          TextButton.icon(
            onPressed: () =>
                Navigator.pop(context, DeliveryAction.notDelivered),
            icon: const Icon(AppIcons.undo, size: 18),
            label: const Text('Not delivered yet'),
          ),
        TextButton.icon(
          onPressed: () => Navigator.pop(context, DeliveryAction.notADelivery),
          icon: const Icon(AppIcons.hide, size: 18),
          label: const Text('Not a delivery'),
        ),
      ],
      children: [
        DetailSection(
          title: 'Emails',
          children: [
            for (final r in d.records)
              ListTile(
                key: ValueKey('delivery-email-${r.email.messageId.value}'),
                leading: Icon(DeliveryText.icon(r.status)),
                title: Text(DeliveryText.event(r.status)),
                subtitle: Text(
                  '${date(r.email.at)} · '
                  '${r.email.subject.isEmpty ? '(no subject)' : r.email.subject}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(AppIcons.chevron),
                onTap: () => _openEmail(context, r.email.messageId),
              ),
          ],
        ),
      ],
    );
  }
}
