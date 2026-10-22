// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'mail_text.dart';

/// "Move to…": the folders of the messages' account, with a filter box for
/// long folder lists, and (for one message) "always move mail from this
/// sender here".
abstract final class MoveDialog {
  static Future<void> show(
    BuildContext context,
    MailController controller,
    List<StoredMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    if (messages.map((m) => m.accountId).toSet().length > 1) return;
    final result = await showDialog<(StoredMailbox, bool)>(
      context: context,
      builder: (_) => _MoveDialog(controller: controller, messages: messages),
    );
    if (result == null) return;
    final (target, always) = result;
    if (always && messages.length == 1 && controller.canHaveRules(target)) {
      controller.moveAlways(messages.single, target);
    } else {
      controller.moveTo(messages, target);
    }
  }
}

final class _MoveDialog extends StatefulWidget {
  const _MoveDialog({required this.controller, required this.messages});

  final MailController controller;
  final List<StoredMessage> messages;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

final class _MoveDialogState extends State<_MoveDialog> {
  String _filter = '';
  bool _always = false;

  @override
  Widget build(BuildContext context) {
    final first = widget.messages.first;
    final folders = widget.controller
        .moveTargets(first)
        .where((b) => widget.messages.every((m) => m.mailboxId != b.id))
        .where(
          (b) =>
              _filter.isEmpty ||
              b.name.toLowerCase().contains(_filter.toLowerCase()) ||
              MailText.folder(b).toLowerCase().contains(_filter.toLowerCase()),
        )
        .toList();
    final sender = widget.messages.length == 1 ? first.from?.address : null;
    return AlertDialog(
      title: Text(
        widget.messages.length == 1
            ? 'Move to'
            : 'Move ${widget.messages.length} messages to',
      ),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Find a folder',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _filter = v.trim()),
                onSubmitted: (_) {
                  if (folders.length == 1) {
                    Navigator.pop(context, (folders.single, _always));
                  }
                },
              ),
            ),
            if (sender != null)
              CheckboxListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                controlAffinity: ListTileControlAffinity.leading,
                value: _always,
                onChanged: (v) => setState(() => _always = v ?? false),
                title: Text('Always move mail from $sender here'),
              ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final box in folders)
                    ListTile(
                      leading: Icon(MailText.folderIcon(box), size: 20),
                      title: Text(
                        box.isInbox
                            ? 'Inbox'
                            : box.name.replaceAll(box.delimiter ?? '/', ' / '),
                      ),
                      onTap: () => Navigator.pop(context, (box, _always)),
                    ),
                ],
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
      ],
    );
  }
}
