// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import '../mail/mail_controller.dart';
import 'attachment_saver.dart';
import 'avatar.dart';
import 'link_opener.dart';
import 'mail_text.dart';
import 'rich_document_view.dart';

/// The right pane: actions, the message header, its body and attachments.
final class ReaderPane extends StatelessWidget {
  const ReaderPane({
    super.key,
    required this.controller,
    this.showBack = false,
  });

  final MailController controller;

  /// On phones the reader covers the list, so it needs a way back.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final reader = controller.reader;
    final message = controller.selected;
    if (message == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mail_outline,
              size: 48,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Select a message to read it',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(controller: controller, message: message, showBack: showBack),
        const Divider(),
        Expanded(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: SelectionArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                children: [
                  Text(
                    MailText.subject(message),
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 16),
                  // The message sits on a card, as in Spark.
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant
                            .withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Sender(message: message, reader: reader),
                        const SizedBox(height: 16),
                        ...switch (reader) {
                          ReaderLoading() => [
                            const Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ],
                          ReaderFailed(:final reason) => [
                            _Notice(icon: Icons.cloud_off, text: reason),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () => controller.open(message),
                                child: const Text('Try again'),
                              ),
                            ),
                          ],
                          ReaderReady(:final view) && final ready => [
                            if (view.body.blockedImages > 0)
                              _Notice(
                                icon: Icons.shield_outlined,
                                text: view.body.blockedImages == 1
                                    ? '1 remote image was blocked, so the sender can\'t tell you opened this.'
                                    : '${view.body.blockedImages} remote images were blocked, so the sender can\'t '
                                          'tell you opened this.',
                              ),
                            if (view.body.truncated)
                              const _Notice(
                                icon: Icons.content_cut,
                                text: 'Part of this message was too large or complex to show.',
                              ),
                            RichDocumentView(
                              document: view.body,
                              onLink: (link) => LinkOpener.open(
                                context,
                                link,
                                onMailto: controller.composeTo,
                              ),
                            ),
                            if (view.attachments.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              _Attachments(attachments: view.attachments),
                            ],
                            const SizedBox(height: 20),
                            _ReplyBar(controller: controller, reader: ready),
                          ],
                          ReaderEmpty() => const [],
                        },
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.message,
    required this.showBack,
  });

  final MailController controller;
  final StoredMessage message;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final archive = controller.archiveFor(message);
    final inTrash = controller.isInTrash(message);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: showBack ? 'Back' : 'Close',
            icon: Icon(showBack ? Icons.arrow_back : Icons.close),
            onPressed: controller.closeMessage,
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: message.flags.flagged ? 'Unpin' : 'Pin',
            isSelected: message.flags.flagged,
            icon: const Icon(Icons.push_pin_outlined),
            selectedIcon: const Icon(Icons.push_pin, color: Color(0xFFE5484D)),
            onPressed: () => controller.togglePin(message),
          ),
          IconButton(
            tooltip: message.flags.seen ? 'Mark as unread' : 'Mark as read',
            icon: Icon(
              message.flags.seen
                  ? Icons.mark_email_unread_outlined
                  : Icons.mark_email_read_outlined,
            ),
            onPressed: () => controller.toggleRead(message),
          ),
          if (archive != null && archive.id != message.mailboxId)
            IconButton(
              tooltip: 'Archive',
              icon: const Icon(Icons.archive_outlined),
              onPressed: () => controller.archive(message),
            ),
          IconButton(
            tooltip: inTrash ? 'Delete forever' : 'Move to Trash',
            icon: Icon(
              inTrash ? Icons.delete_forever_outlined : Icons.delete_outline,
            ),
            onPressed: () => _delete(context, inTrash),
          ),
          IconButton(
            tooltip: 'Move to folder',
            icon: const Icon(Icons.drive_file_move_outline),
            onPressed: () => _move(context),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, bool forever) async {
    if (forever) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete forever?'),
          content: const Text(
            'This message will be deleted from the server and can\'t be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    controller.delete(message);
  }

  Future<void> _move(BuildContext context) async {
    final targets = controller.moveTargets(message);
    var always = false;
    final sender = message.from?.address;
    final target = await showDialog<StoredMailbox>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => SimpleDialog(
          title: const Text('Move to'),
          children: [
            if (sender != null)
              CheckboxListTile(
                value: always,
                onChanged: (v) => setState(() => always = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('Always move mail from $sender here'),
              ),
            for (final box in targets)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, box),
                child: Row(
                  children: [
                    Icon(MailText.folderIcon(box), size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        box.isInbox
                            ? 'Inbox'
                            : box.name.replaceAll(box.delimiter ?? '/', ' / '),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    if (always && controller.canHaveRules(target)) {
      controller.moveAlways(message, target);
    } else {
      controller.moveTo(message, target);
    }
  }
}

final class _Sender extends StatelessWidget {
  const _Sender({required this.message, required this.reader});

  final StoredMessage message;
  final ReaderState reader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = message.from;
    final muted = theme.colorScheme.onSurfaceVariant;
    final (to, cc) = switch (reader) {
      ReaderReady(:final to, :final cc) => (to, cc),
      _ => (const <MailAddress>[], const <MailAddress>[]),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Avatar(name: MailText.sender(message), address: from?.address ?? ''),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      MailText.sender(message),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Shares the row with the name, so long dates never push
                  // the name out on narrow screens.
                  Flexible(
                    flex: 2,
                    child: Text(
                      MailText.fullDate(
                        context,
                        message.sentAt ?? message.receivedAt,
                      ),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
              if (from != null)
                Text(
                  from.address,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              if (to.isNotEmpty)
                Text(
                  'To: ${to.map(MailText.address).join(', ')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (cc.isNotEmpty)
                Text(
                  'Cc: ${cc.map(MailText.address).join(', ')}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: colors.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

final class _Attachments extends StatelessWidget {
  const _Attachments({required this.attachments});

  final List<AttachmentView> attachments;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final attachment in attachments)
        ActionChip(
          avatar: const Icon(Icons.attach_file, size: 18),
          label: Text(
            '${attachment.displayName} · ${MailText.size(attachment.approximateSize)}',
          ),
          tooltip: 'Save to Downloads',
          onPressed: () => _save(context, attachment),
        ),
    ],
  );

  Future<void> _save(BuildContext context, AttachmentView attachment) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await AttachmentSaver.save(attachment);
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t save ${attachment.displayName}.')),
      );
    }
  }
}

/// Reply, Reply all and Forward under the message, as in Spark.
final class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.controller, required this.reader});

  final MailController controller;
  final ReaderReady reader;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton.icon(
        onPressed: () => controller.reply(reader),
        icon: const Icon(Icons.reply, size: 18),
        label: const Text('Reply'),
      ),
      OutlinedButton.icon(
        onPressed: () => controller.replyAll(reader),
        icon: const Icon(Icons.reply_all, size: 18),
        label: const Text('Reply all'),
      ),
      OutlinedButton.icon(
        onPressed: () => controller.forward(reader),
        icon: const Icon(Icons.forward, size: 18),
        label: const Text('Forward'),
      ),
    ],
  );
}
