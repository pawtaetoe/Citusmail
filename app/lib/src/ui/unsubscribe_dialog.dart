// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import 'block_dialog.dart';
import 'link_opener.dart';
import 'trust_banner.dart';

/// Asks before unsubscribing, says exactly what will happen, and offers
/// the next method if one fails.
final class UnsubscribeDialog extends StatefulWidget {
  const UnsubscribeDialog({
    super.key,
    required this.controller,
    required this.reader,
  });

  final MailController controller;
  final ReaderReady reader;

  static Future<void> show(
    BuildContext context,
    MailController controller,
    ReaderReady reader,
  ) => showDialog<void>(
    context: context,
    builder: (_) => UnsubscribeDialog(controller: controller, reader: reader),
  );

  @override
  State<UnsubscribeDialog> createState() => _UnsubscribeDialogState();
}

final class _UnsubscribeDialogState extends State<UnsubscribeDialog> {
  late UnsubscribeMethod _method = widget.reader.unsubscribe.preferred!;
  late final int _inInbox = widget.controller.sameList(widget.reader).length;
  bool _archive = false;
  bool _busy = false;

  /// Why the last attempt failed.
  String? _problem;

  UnsubscribePlan get _plan => widget.reader.unsubscribe;
  String get _name => _plan.listName;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text('Unsubscribe from $_name?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_problem case final problem?) ...[
              TrustReasons(level: TrustLevel.caution, reasons: [problem]),
              const SizedBox(height: 12),
            ],
            Text(_explanation(), style: text.bodyMedium),
            if (widget.reader.trust.level == TrustLevel.caution) ...[
              const SizedBox(height: 8),
              Text(
                'This sender couldn\'t be fully checked. Unsubscribing tells '
                'them your address is read; if you never signed up, deleting '
                'the message is safer.',
                style: text.bodySmall,
              ),
            ],
            if (_inInbox > 0) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _archive,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _archive = v ?? false),
                title: Text(
                  _inInbox == 1
                      ? 'Also archive this message'
                      : 'Also archive the $_inInbox messages from this list in your inbox',
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: Text(switch (_method) {
            WebPageMethod() => 'Open page',
            EmailMethod() => 'Send email',
            OneClickMethod() => 'Unsubscribe',
          }),
        ),
      ],
    );
  }

  String _explanation() => switch (_method) {
    OneClickMethod(:final url) =>
      '$appName asks ${url.host} to stop sending you this list. Nothing else '
          'about you is sent.',
    EmailMethod(:final request) =>
      '$appName sends an unsubscribe email from your address to '
          '${request.address}. A copy goes to your Sent folder.',
    WebPageMethod(:final url) =>
      'This list unsubscribes on its website, ${url.host}. The page opens '
          'in your browser; finish there.\n\n${url.toString()}',
  };

  Future<void> _go() async {
    final method = _method;
    if (method is WebPageMethod) {
      final opened = await LinkOpener.launch(context, method.url);
      if (!opened || !mounted) return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final problem = await widget.controller.unsubscribe(
      widget.reader,
      method,
      archiveList: _archive,
    );
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context);
      return;
    }
    // Offer the next way, if there is one.
    final next = _plan.after(method).firstOrNull;
    setState(() {
      _busy = false;
      _problem = next == null ? problem : '$problem ${_fallbackHint(next)}';
      if (next != null) _method = next;
    });
  }

  static String _fallbackHint(UnsubscribeMethod next) => switch (next) {
    EmailMethod() => 'You can send an unsubscribe email instead.',
    WebPageMethod() => 'You can use their unsubscribe page instead.',
    OneClickMethod() => '',
  };
}

/// "Unsubscribe", or what happened before, under the sender.
final class UnsubscribeStatus extends StatelessWidget {
  const UnsubscribeStatus({
    super.key,
    required this.controller,
    required this.reader,
  });

  final MailController controller;
  final ReaderReady reader;

  /// Lists must stop within two days (what large providers require of
  /// bulk senders); later mail means the unsubscribe was ignored.
  static const grace = Duration(days: 2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = reader.unsubscribed;
    if (record != null) {
      final ignored = reader.message.receivedAt.isAfter(record.at.add(grace));
      final when = MaterialLocalizations.of(context)
          .formatMediumDate(record.at.toLocal());
      final said = switch (record.kind) {
        UnsubscribeKind.webPage => 'You opened the unsubscribe page on $when.',
        _ => 'You unsubscribed on $when.',
      };
      if (!ignored) {
        return Text(
          said,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        );
      }
      final hint = record.kind == UnsubscribeKind.webPage
          ? ' The page may need another step.'
          : '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrustReasons(
            level: TrustLevel.caution,
            reasons: [
              '$said ${reader.unsubscribe.listName} is still sending.$hint',
            ],
          ),
          if (controller.blockFor(reader.message) == null &&
              controller.canBlock(reader.message))
            TextButton.icon(
              icon: const Icon(Icons.block, size: 18),
              label: const Text('Block sender'),
              onPressed: () =>
                  BlockDialog.show(context, controller, reader.message),
            ),
        ],
      );
    }
    if (!reader.unsubscribe.available) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        icon: const Icon(Icons.unsubscribe_outlined, size: 18),
        label: const Text('Unsubscribe'),
        onPressed: () => UnsubscribeDialog.show(context, controller, reader),
      ),
    );
  }
}
