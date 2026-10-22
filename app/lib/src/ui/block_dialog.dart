// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import '../services/app_services.dart';

/// Asks how to block a message's sender.
final class BlockDialog extends StatefulWidget {
  const BlockDialog({
    super.key,
    required this.controller,
    required this.choice,
  });

  final MailController controller;
  final BlockChoice choice;

  /// Shows the dialog for [message]'s sender; does nothing if it can't be
  /// blocked (no sender, or the user's own address).
  static Future<void> show(
    BuildContext context,
    MailController controller,
    StoredMessage message,
  ) async {
    final choice = controller.blockChoice(message);
    if (choice == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => BlockDialog(controller: controller, choice: choice),
    );
  }

  @override
  State<BlockDialog> createState() => _BlockDialogState();
}

final class _BlockDialogState extends State<BlockDialog> {
  BlockKind _kind = BlockKind.address;
  bool _move = true;

  BlockChoice get _choice => widget.choice;

  int get _count =>
      _kind == BlockKind.address ? _choice.fromAddress : _choice.fromDomain;

  @override
  Widget build(BuildContext context) {
    final domain = _choice.domain;
    return AlertDialog(
      title: const Text('Block this sender?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'New mail from them goes straight to Junk, with no '
              'notification. They aren\'t told. You can unblock them in '
              'Settings.',
            ),
            const SizedBox(height: 12),
            RadioGroup<BlockKind>(
              groupValue: _kind,
              onChanged: (kind) => setState(() => _kind = kind ?? _kind),
              child: Column(
                children: [
                  RadioListTile<BlockKind>(
                    contentPadding: EdgeInsets.zero,
                    value: BlockKind.address,
                    title: Text('Only ${_choice.address}'),
                  ),
                  if (domain != null)
                    RadioListTile<BlockKind>(
                      contentPadding: EdgeInsets.zero,
                      value: BlockKind.domain,
                      title: Text('Everyone at $domain'),
                    ),
                ],
              ),
            ),
            if (_count > 0)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _move,
                onChanged: (v) => setState(() => _move = v ?? false),
                title: Text(
                  _count == 1
                      ? 'Also move the message from them in your inbox to Junk'
                      : 'Also move the $_count messages from them in your inbox to Junk',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            widget.controller.block(
              _kind,
              _kind == BlockKind.domain ? domain! : _choice.address,
              moveExisting: _move && _count > 0,
            );
          },
          child: const Text('Block'),
        ),
      ],
    );
  }
}

/// Settings > Blocked senders: every block, each with Unblock.
final class BlockedSendersPage extends StatefulWidget {
  const BlockedSendersPage({super.key, required this.services});

  final AppServices services;

  @override
  State<BlockedSendersPage> createState() => _BlockedSendersPageState();
}

final class _BlockedSendersPageState extends State<BlockedSendersPage> {
  BlockRepository get _blocks => widget.services.store.blocks;

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks.all();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked senders')),
      body: blocks.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No one is blocked. To block a sender, open one of their '
                  'messages and choose Block sender.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
              ),
            )
          : ListView(
              children: [
                for (final block in blocks)
                  ListTile(
                    leading: Icon(
                      block.kind == BlockKind.domain
                          ? Icons.domain_disabled_outlined
                          : Icons.person_off_outlined,
                    ),
                    title: Text(
                      block.kind == BlockKind.domain
                          ? 'Everyone at ${block.value}'
                          : block.value,
                    ),
                    subtitle: Text(
                      'Since ${MaterialLocalizations.of(context).formatMediumDate(block.since.toLocal())}',
                    ),
                    trailing: TextButton(
                      onPressed: () {
                        _blocks.unblock(block.id);
                        setState(() {});
                      },
                      child: const Text('Unblock'),
                    ),
                  ),
              ],
            ),
    );
  }
}
