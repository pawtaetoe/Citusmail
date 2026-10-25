// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import 'attachment_saver.dart';
import 'avatar.dart';
import 'block_dialog.dart';
import 'fmail_theme.dart';
import 'link_opener.dart';
import 'mail_text.dart';
import 'move_dialog.dart';
import 'rich_document_view.dart';
import 'trust_banner.dart';
import 'unsubscribe_dialog.dart';
import 'virus_total_check.dart';

/// The right pane: actions, the message header, its body (built lazily,
/// block by block) and attachments, in a column of comfortable reading
/// width, with Reply, Reply all and Forward always in reach at the bottom.
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
                  safety: controller.services.linkSafety.check,
                  virusTotal: controller.services.virusTotal.enabled
                      ? controller.services.virusTotal.link
                      : null,
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
                              images:
                                  reader is ReaderReady &&
                                      reader.imagesShown &&
                                      reader.imagesAllowed
                                  ? controller.services.images.load
                                  : null,
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
                                  virusTotal:
                                      controller.services.virusTotal.enabled
                                      ? controller.services.virusTotal.file
                                      : null,
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
          if (reader is ReaderReady)
            _ReplyBar(controller: controller, reader: reader),
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
          const CitusMark(size: 40),
          const SizedBox(height: 16),
          Text(
            'Select a message to read it',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Press ? for keyboard shortcuts',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
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
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 18),
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
          _PrivacyNotice(controller: controller, reader: ready),
          if (controller.receiptsFor(ready.message) case final receipts?)
            _ReceiptNotice(receipts: receipts),
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
    // Grouped by what they do: where it goes, how it's marked, the sender.
    // Replying is in the bar under the message.
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
        group: 1,
      ),
      _Action(
        message.flags.seen ? 'Mark as unread (U)' : 'Mark as read (U)',
        message.flags.seen
            ? Icons.mark_email_unread_outlined
            : Icons.mark_email_read_outlined,
        () => controller.toggleRead([message]),
        group: 1,
      ),
      if (controller.blockFor(message) case final block?)
        _Action(
          'Unblock sender',
          Icons.how_to_reg_outlined,
          () => controller.unblock(block),
          group: 2,
        )
      else if (controller.canBlock(message))
        _Action(
          'Block sender',
          Icons.block,
          () => BlockDialog.show(context, controller, message),
          group: 2,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Back button + as many 48dp buttons (and group rules) as fit; the
        // rest in "More".
        final room = ((constraints.maxWidth - 64 - 2 * 17) / 48).floor().clamp(
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
              for (final (i, a) in shown.indexed) ...[
                if (i > 0 && shown[i - 1].group != a.group)
                  const SizedBox(height: 24, child: VerticalDivider(width: 17)),
                IconButton(
                  tooltip: a.label,
                  icon: Icon(a.icon, color: a.color),
                  onPressed: a.onPressed,
                ),
              ],
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
  const _Action(
    this.label,
    this.icon,
    this.onPressed, {
    this.color,
    this.group = 0,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  /// Neighbouring actions with different groups get a rule between them.
  final int group;
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
    final date = Text(
      MailText.fullDate(context, message.sentAt ?? message.receivedAt),
      style: theme.textTheme.bodySmall?.copyWith(color: muted),
    );
    // Phones: the date gets its own line instead of wrapping beside the name.
    final narrow = MediaQuery.sizeOf(context).width < 520;
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
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (!narrow) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: DefaultTextStyle.merge(
                        textAlign: TextAlign.end,
                        child: date,
                      ),
                    ),
                  ],
                ],
              ),
              if (from != null)
                Text(
                  from.address,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              if (narrow) date,
              if (to.isNotEmpty)
                Text(
                  'To: ${to.map(MailText.address).join(', ')}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
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

/// What the app kept from the sender: trackers, hidden images (with the
/// choice to load them), and an ignored read-receipt request.
final class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice({required this.controller, required this.reader});

  final MailController controller;
  final ReaderReady reader;

  @override
  Widget build(BuildContext context) {
    final body = reader.view.body;
    final trackers = body.trackers == 1
        ? 'Blocked a tracker'
        : 'Blocked ${body.trackers} trackers';
    final images = body.remoteImages == 1
        ? '1 image is'
        : '${body.remoteImages} images are';
    final lines = <String>[
      if (body.trackers > 0)
        '$trackers that would tell ${_hosts(body.trackerHosts)} when you open this.',
      if (body.remoteImages > 0 && !reader.imagesShown)
        reader.imagesAllowed
            ? '$images hidden. Loading them shows the sender your IP address '
                  'and that you opened this.'
            : 'Images are hidden because this message may be a scam.',
      if (reader.view.message.headers.contains('disposition-notification-to'))
        'The sender asked to be told when you read this. $appName didn\'t tell them.',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final canLoad =
        body.remoteImages > 0 && !reader.imagesShown && reader.imagesAllowed;
    // The app's promise at work, so it gets the brand's colour.
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.fromLTRB(14, 12, 14, canLoad ? 4 : 8),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(FmailTheme.radius),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 20, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      line,
                      style: TextStyle(color: colors.onPrimaryContainer),
                    ),
                  ),
                if (canLoad)
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: () => controller.showImages(reader),
                        child: const Text('Load images'),
                      ),
                      if (reader.trust.verified)
                        TextButton(
                          onPressed: () =>
                              controller.showImages(reader, always: true),
                          child: const Text('Always from this sender'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _hosts(Set<String> hosts) {
    if (hosts.isEmpty) return 'the sender';
    final list = hosts.take(2).toList();
    return list.length < hosts.length
        ? '${list.join(', ')} and others'
        : list.join(' and ');
  }
}

/// On the user's own mail that asked for read receipts.
final class _ReceiptNotice extends StatelessWidget {
  const _ReceiptNotice({required this.receipts});

  final List<ReadReceipt> receipts;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dates = MaterialLocalizations.of(context);
    String when(DateTime at) {
      final local = at.toLocal();
      return '${dates.formatMediumDate(local)}, '
          '${TimeOfDay.fromDateTime(local).format(context)}';
    }

    const waiting =
        'Read receipt requested. No answer yet: the recipient\'s mail app '
        'decides whether to send one.';
    final lines = receipts.isEmpty
        ? const [waiting]
        : [
            for (final r in receipts)
              '${switch (r.disposition) {
                'displayed' => 'Read by',
                'deleted' => 'Deleted unread by',
                _ => 'Received by',
              }} ${r.recipient} · ${when(r.at)}',
          ];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(FmailTheme.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            receipts.isEmpty
                ? Icons.mark_email_unread_outlined
                : Icons.done_all,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  Text(line, style: TextStyle(color: colors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
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
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(FmailTheme.radius),
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
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(FmailTheme.radius),
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
  const _Attachments({
    required this.attachments,
    required this.trust,
    this.virusTotal,
  });

  final List<AttachmentView> attachments;
  final TrustReport trust;

  /// VirusTotal by file hash, when the user turned it on.
  final Future<VirusTotalReport> Function(List<int> bytes)? virusTotal;

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
    if (verdict != null &&
        !await _confirm(context, verdict, attachment, virusTotal)) {
      return;
    }
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
    AttachmentView attachment,
    Future<VirusTotalReport> Function(List<int> bytes)? virusTotal,
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
              if (virusTotal != null) ...[
                const SizedBox(height: 8),
                VirusTotalCheck(
                  what: 'file',
                  lookup: () => virusTotal(attachment.bytes()),
                ),
              ],
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

/// Reply, Reply all and Forward, pinned under the message so they are
/// always in reach, lined up with the reading column.
final class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.controller, required this.reader});

  final MailController controller;
  final ReaderReady reader;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = max(
            16.0,
            (constraints.maxWidth - ReaderPane.readingWidth) / 2,
          );
          final narrow = constraints.maxWidth < 420;
          Widget button(
            String label,
            String tooltip,
            IconData icon,
            VoidCallback onPressed, {
            bool main = false,
          }) {
            // Phones: the three share the width, without icons to fit.
            final style = narrow
                ? const ButtonStyle(
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8),
                    ),
                  )
                : null;
            final Widget child = switch ((main, narrow)) {
              (true, true) => FilledButton.tonal(
                style: style,
                onPressed: onPressed,
                child: Text(label),
              ),
              (true, false) => FilledButton.tonalIcon(
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
              (false, true) => OutlinedButton(
                style: style,
                onPressed: onPressed,
                child: Text(label),
              ),
              (false, false) => OutlinedButton.icon(
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
            };
            final tip = Tooltip(message: tooltip, child: child);
            return narrow ? Expanded(child: tip) : tip;
          }

          final buttons = [
            button(
              'Reply',
              'Reply (R)',
              Icons.reply,
              () => controller.reply(reader),
              main: true,
            ),
            button(
              'Reply all',
              'Reply all (A)',
              Icons.reply_all,
              () => controller.replyAll(reader),
            ),
            button(
              'Forward',
              'Forward (F)',
              Icons.forward,
              () => controller.forward(reader),
            ),
          ];
          return Padding(
            padding: EdgeInsets.fromLTRB(side, 10, side, 10),
            child: Row(
              children: [
                for (final (i, b) in buttons.indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  b,
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
