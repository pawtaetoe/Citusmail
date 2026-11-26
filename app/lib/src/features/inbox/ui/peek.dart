// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/text/mail_text.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/citusmail_theme.dart';
import '../../../core/widgets/avatar.dart';
import '../state/mail_controller.dart';
import '../state/message_reads.dart';
import 'mail_shell.dart';

/// A look at an email without opening it: who, what, when and its first
/// lines, with a few actions. It stays unread, no read receipt goes out,
/// and nothing loads from the web: only the text is shown, as the list's
/// preview or the downloaded body's plain text. A body not on the device
/// yet is downloaded from the user's own mail server the way opening
/// does (it stays unread there too).
///
/// Phones: a sheet from the bottom (press and hold a row). Wider screens:
/// a card beside the list (Space on the row in focus); Space or Esc
/// closes it.
abstract final class Peek {
  /// Lines of text shown at most.
  static const lines = 12;

  /// The card's width beside the list.
  static const width = 440.0;

  /// Shows [message]; [anchor] is its row, in global coordinates, to put
  /// the card beside it on wider screens.
  static Future<void> show(
    BuildContext context,
    MailController controller,
    StoredMessage message, {
    Rect? anchor,
  }) {
    final size = MediaQuery.sizeOf(context);
    final card = PeekCard(controller: controller, message: message);
    if (size.width < MailShell.mediumWidth) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        constraints: BoxConstraints(maxHeight: size.height * 0.85),
        builder: (_) => _closesWithSpace(card),
      );
    }
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.12),
      builder: (context) => _closesWithSpace(
        CustomSingleChildLayout(
          delegate: _Beside(anchor),
          child: Semantics(
            scopesRoute: true,
            namesRoute: true,
            explicitChildNodes: true,
            label: 'Peek',
            child: Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(CitusmailTheme.radiusCard),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Space closes the peek too (Esc does on its own).
  static Widget _closesWithSpace(Widget child) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.space): DismissIntent(),
    },
    child: Focus(autofocus: true, child: child),
  );

  /// The first [lines] lines of [text], without runs of blank lines.
  static String excerpt(String text) {
    final kept = <String>[];
    var gap = false;
    for (final raw in text.replaceAll('\r', '').split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        gap = kept.isNotEmpty;
        continue;
      }
      if (gap) kept.add('');
      gap = false;
      kept.add(line);
      if (kept.length >= lines) break;
    }
    return kept.join('\n');
  }
}

/// Puts the card beside [anchor] (the row), else in the middle.
final class _Beside extends SingleChildLayoutDelegate {
  const _Beside(this.anchor);

  final Rect? anchor;

  static const _margin = 16.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: (constraints.maxWidth - 2 * _margin).clamp(0, Peek.width),
        maxHeight: (constraints.maxHeight - 2 * _margin).clamp(0, 640),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final a = anchor;
    final middle = Offset(
      (size.width - child.width) / 2,
      (size.height - child.height) / 2,
    );
    if (a == null || a.right + 12 + child.width > size.width - _margin) {
      return middle;
    }
    final top = (a.top - 24).clamp(
      _margin,
      (size.height - child.height - _margin).clamp(_margin, size.height),
    );
    return Offset(a.right + 12, top);
  }

  @override
  bool shouldRelayout(_Beside old) => old.anchor != anchor;
}

/// What a peek shows: sender, subject, date, the first lines, actions.
final class PeekCard extends StatefulWidget {
  const PeekCard({super.key, required this.controller, required this.message});

  final MailController controller;
  final StoredMessage message;

  @override
  State<PeekCard> createState() => _PeekCardState();
}

final class _PeekCardState extends State<PeekCard> {
  /// The body's first lines, once read; null while loading.
  String? _text;

  /// The body could not be downloaded.
  bool _failed = false;

  MailController get _c => widget.controller;

  MailStore get _store => _c.services.store;

  /// The message as stored now (pinned or read since the list was built).
  StoredMessage get _m =>
      _store.messages.byId(widget.message.id) ?? widget.message;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      if (!MessageReads.downloaded(_store, _m.id)) {
        // BODY.PEEK: it stays unread on the server.
        await _c.services.worker.loadBody(_m.id);
      }
      if (!mounted) return;
      // The same text the pages read, kept per message.
      final [text] = await plainTextReads.read(_store, [_m]);
      if (!mounted) return;
      setState(() => _text = Peek.excerpt(text));
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Closes the peek, then does [action].
  void _then(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    final m = _m;
    final sender = MailText.sender(m);
    final archive = _c.archiveFor(m);
    final canArchive = archive != null && archive.id != m.mailboxId;
    final selected = _c.selection.value.contains(m.id);
    final text = _text;
    final preview = m.snippet?.trim() ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Row(
            children: [
              Avatar(name: sender, address: m.from?.address ?? ''),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sender,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      MailText.dayAndTime(context, m.receivedAt),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Text(
            MailText.subject(m),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text ?? (preview.isEmpty ? ' ' : preview),
                  maxLines: Peek.lines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                if (text == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _failed
                          ? 'Can\'t show more right now. Open it to read '
                                'it all.'
                          : 'Loading…',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              _Action(
                icon: AppIcons.openMessage,
                label: 'Open',
                onPressed: () => _then(() => unawaited(_c.open(m))),
              ),
              _Action(
                icon: AppIcons.select,
                label: selected ? 'Unselect' : 'Select',
                onPressed: () => _then(() => _c.toggleSelected(m)),
              ),
              if (canArchive)
                _Action(
                  icon: AppIcons.archive,
                  label: 'Archive',
                  onPressed: () => _then(() => _c.archive([m])),
                ),
              _Action(
                icon: m.flags.flagged ? AppIcons.pinOn : AppIcons.pinOff,
                label: m.flags.flagged ? 'Unpin' : 'Pin',
                onPressed: () => _then(() => _c.togglePin([m])),
              ),
              _Action(
                icon: m.flags.seen ? AppIcons.markUnread : AppIcons.markRead,
                label: m.flags.seen ? 'Mark unread' : 'Mark read',
                onPressed: () => _then(() => _c.toggleRead([m])),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// An icon with its name under it, sharing the row with the others.
final class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onPressed,
        child: InkWell(
          borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: theme.colorScheme.primary),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
