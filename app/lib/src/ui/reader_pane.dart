// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../mail/mail_controller.dart';
import 'attachment_saver.dart';
import 'avatar.dart';
import 'block_dialog.dart';
import 'link_opener.dart';
import 'mail_text.dart';
import 'move_dialog.dart';
import 'rich_document_view.dart';
import 'trust_banner.dart';
import 'unsubscribe_dialog.dart';

/// The right pane: actions, the message header, its body (built lazily,
/// block by block) and attachments, in a column of comfortable reading
/// width.
final class ReaderPane extends StatelessWidget {
  const ReaderPane({
    super.key,
    required this.controller,
    this.showBack = false,
  });

  final MailController controller;

  /// On phones the reader covers the list, so it needs a way back.
  final bool showBack;

  /// Lines longer than this are hard to read.
  static const readingWidth = 760.0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.reader,
    builder: (context, reader, _) {
      final message = reader.message;
      if (message == null) return const _NothingOpen();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            controller: controller,
            reader: reader,
            message: message,
            showBack: showBack,
          ),
          const Divider(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side = max(
                  20.0,
                  (constraints.maxWidth - readingWidth) / 2,
                );
                final padding = EdgeInsets.symmetric(horizontal: side);
                final view = reader is ReaderReady ? reader.view : null;
                final trust = reader is ReaderReady ? reader.trust : null;
                void onLink(Uri link) => LinkOpener.open(
                  context,
                  link,
                  onMailto: controller.composeTo,
                  trust: trust,
                );
                return SelectionArea(
                  child: CustomScrollView(
                    key: ValueKey(message.id),
                    slivers: [
                      SliverPadding(
                        padding: padding.copyWith(top: 20),
                        sliver: SliverToBoxAdapter(
                          child: _Header(
                            message: message,
                            reader: reader,
                            controller: controller,
                          ),
                        ),
                      ),
                      if (view != null)
                        SliverPadding(
                          padding: padding,
                          sliver: SliverList.builder(
                            itemCount: view.body.blocks.length,
                            itemBuilder: (_, i) => BlockView(
                              block: view.body.blocks[i],
                              onLink: onLink,
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: padding.copyWith(bottom: 40),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (view != null &&
                                  view.attachments.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                _Attachments(
                                  attachments: view.attachments,
                                  trust: trust ?? TrustReport.empty,
                                ),
                              ],
                              if (reader is ReaderReady) ...[
                                const SizedBox(height: 24),
                                _ReplyBar(
                                  controller: controller,
                                  reader: reader,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}

final class _NothingOpen extends StatelessWidget {
  const _NothingOpen();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mail_outline, size: 48, color: colors.outlineVariant),
          const SizedBox(height: 12),
          Text(
            'Select a message to read it',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            'Press ? for keyboard shortcuts',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.outline),
          ),
        ],
      ),
    );
  }
}

/// Subject, sender and notices (blocked images, loading, problems).
final class _Header extends StatelessWidget {
  const _Header({
    required this.message,
    required this.reader,
    required this.controller,
  });

  final StoredMessage message;
  final ReaderState reader;
  final MailController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        MailText.subject(message),
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 16),
      _Sender(message: message, reader: reader),
      const SizedBox(height: 20),
      if (controller.blockFor(message) case final block?)
        _BlockedNotice(controller: controller, block: block),
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
        final ReaderReady ready => [
          TrustBanner(report: ready.trust),
          if (ready.unsubscribe.available || ready.unsubscribed != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: UnsubscribeStatus(controller: controller, reader: ready),
            ),
          if (ready.view.body.blockedImages > 0)
            _Notice(
              icon: Icons.shield_outlined,
              text: ready.view.body.blockedImages == 1
                  ? '1 remote image was blocked, so the sender can\'t tell you opened this.'
                  : '${ready.view.body.blockedImages} remote images were blocked, so the sender can\'t '
                        'tell you opened this.',
            ),
          if (ready.view.body.truncated)
            const _Notice(
              icon: Icons.content_cut,
              text: 'Part of this message was too large or complex to show.',
            ),
        ],
        ReaderEmpty() => const [],
      },
    ],
  );
}

/// The reader's actions. On narrow screens the less frequent ones move into
/// a "More" menu, so every button keeps a comfortable size.
final class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.reader,
    required this.message,
    required this.showBack,
  });

  final MailController controller;
  final ReaderState reader;
  final StoredMessage message;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final archive = controller.archiveFor(message);
    final inTrash = controller.isInTrash(message);
    final ready = reader is ReaderReady ? reader as ReaderReady : null;
    final actions = <_Action>[
      if (archive != null && archive.id != message.mailboxId)
        _Action(
          'Archive (E)',
          Icons.archive_outlined,
          () => controller.archive([message]),
        ),
      _Action(
        inTrash ? 'Delete forever' : 'Move to Trash (#)',
        inTrash ? Icons.delete_forever_outlined : Icons.delete_outline,
        () => _delete(context, inTrash),
      ),
      _Action(
        'Move to folder (V)',
        Icons.drive_file_move_outline,
        () => MoveDialog.show(context, controller, [message]),
      ),
      _Action(
        message.flags.flagged ? 'Unpin (S)' : 'Pin (S)',
        message.flags.flagged ? Icons.push_pin : Icons.push_pin_outlined,
        () => controller.togglePin([message]),
        color: message.flags.flagged ? MailText.pinColor : null,
      ),
      _Action(
        message.flags.seen ? 'Mark as unread (U)' : 'Mark as read (U)',
        message.flags.seen
            ? Icons.mark_email_unread_outlined
            : Icons.mark_email_read_outlined,
        () => controller.toggleRead([message]),
      ),
      if (ready != null) ...[
        _Action('Reply (R)', Icons.reply, () => controller.reply(ready)),
        _Action(
          'Reply all (A)',
          Icons.reply_all,
          () => controller.replyAll(ready),
        ),
        _Action('Forward (F)', Icons.forward, () => controller.forward(ready)),
      ],
      if (controller.blockFor(message) case final block?)
        _Action(
          'Unblock sender',
          Icons.how_to_reg_outlined,
          () => controller.unblock(block),
        )
      else if (controller.canBlock(message))
        _Action(
          'Block sender',
          Icons.block,
          () => BlockDialog.show(context, controller, message),
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Back button + as many 48dp buttons as fit; the rest in "More".
        final room = ((constraints.maxWidth - 64) / 48).floor().clamp(
          2,
          actions.length,
        );
        final shown = room >= actions.length
            ? actions
            : actions.take(room - 1).toList();
        final more = actions.skip(shown.length).toList();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              IconButton(
                tooltip: showBack ? 'Back (Esc)' : 'Close (Esc)',
                icon: Icon(showBack ? Icons.arrow_back : Icons.close),
                onPressed: controller.closeMessage,
              ),
              const Spacer(),
              for (final a in shown)
                IconButton(
                  tooltip: a.label,
                  icon: Icon(a.icon, color: a.color),
                  onPressed: a.onPressed,
                ),
              if (more.isNotEmpty)
                PopupMenuButton<VoidCallback>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    for (final a in more)
                      PopupMenuItem(
                        value: a.onPressed,
                        child: Row(
                          children: [
                            Icon(a.icon, size: 20),
                            const SizedBox(width: 12),
                            Text(a.label),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
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
    controller.delete([message]);
  }
}

final class _Action {
  const _Action(this.label, this.icon, this.onPressed, {this.color});

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;
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

/// Shown on mail from a sender the user blocked.
final class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice({required this.controller, required this.block});

  final MailController controller;
  final BlockedSender block;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.block, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              block.kind == BlockKind.domain
                  ? 'You blocked everyone at ${block.value}.'
                  : 'You blocked ${block.value}.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () => controller.unblock(block),
            child: const Text('Unblock'),
          ),
        ],
      ),
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
  const _Attachments({required this.attachments, required this.trust});

  final List<AttachmentView> attachments;
  final TrustReport trust;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final attachment in attachments)
        _chip(context, attachment, trust.attachment(attachment.fileName)),
    ],
  );

  Widget _chip(
    BuildContext context,
    AttachmentView attachment,
    AttachmentVerdict? verdict,
  ) {
    final style = verdict == null
        ? null
        : TrustStyle.of(context, verdict.level);
    return ActionChip(
      avatar: Icon(
        style?.icon ?? Icons.attach_file,
        size: 18,
        color: style?.foreground,
      ),
      backgroundColor: style?.background,
      label: Text(
        '${attachment.displayName} · ${MailText.size(attachment.approximateSize)}',
        style: style == null ? null : TextStyle(color: style.foreground),
      ),
      tooltip: verdict == null ? 'Save to Downloads' : verdict.reason,
      onPressed: () => _save(context, attachment, verdict),
    );
  }

  Future<void> _save(
    BuildContext context,
    AttachmentView attachment,
    AttachmentVerdict? verdict,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    if (verdict != null && !await _confirm(context, verdict)) return;
    try {
      final file = await AttachmentSaver.save(attachment);
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${file.path}')));
    } on Object {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t save ${attachment.displayName}.')),
      );
    }
  }

  /// Asks before saving a risky file; "Don't save" is the main button.
  static Future<bool> _confirm(
    BuildContext context,
    AttachmentVerdict verdict,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save this file anyway?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                verdict.fileName,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TrustReasons(level: verdict.level, reasons: [verdict.reason]),
              const SizedBox(height: 12),
              const Text(
                'Only open it if you were expecting it from someone you know.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save anyway'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Don\'t save'),
            ),
          ],
        ),
      ) ??
      false;
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
