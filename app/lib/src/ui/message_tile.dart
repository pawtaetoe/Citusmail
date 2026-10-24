// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'avatar.dart';
import 'fmail_theme.dart';
import 'mail_text.dart';

/// One message in a list: the sender's initials, sender, time, subject and
/// preview, with an unread dot. Every row has the same height, so long lists
/// scroll smoothly.
///
/// - Click opens; Ctrl/Cmd-click or the checkbox selects; Shift-click
///   selects a range.
/// - On hover (desktop): archive, delete, pin and read buttons.
/// - On touch: swipe right to archive, left to delete; long-press selects.
/// - Right-click or the menu key: the same actions in a menu.
final class MessageTile extends StatefulWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.controller,
    required this.open,
    required this.checked,
    required this.selecting,
  });

  final StoredMessage message;
  final MailController controller;

  /// It is the message in the reading pane.
  final bool open;

  /// It is selected for a bulk action.
  final bool checked;

  /// Selection mode: taps select instead of opening.
  final bool selecting;

  /// Rows are laid out with this prototype (the same height for all).
  static StoredMessage prototype = StoredMessage(
    id: -1,
    mailboxId: -1,
    accountId: -1,
    uid: 1,
    receivedAt: DateTime.utc(2026),
    size: 0,
    flags: MessageFlags.none,
    hasAttachments: false,
    category: MessageCategory.general,
    categorySource: CategorySource.rule,
    subject: 'Subject',
    snippet: 'Preview',
  );

  @override
  State<MessageTile> createState() => _MessageTileState();
}

final class _MessageTileState extends State<MessageTile> {
  bool _hovered = false;

  StoredMessage get _m => widget.message;
  MailController get _c => widget.controller;

  bool get _touch => switch (Theme.of(context).platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };

  void _tap() {
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed && widget.selecting) {
      _c.selectRange(_m);
    } else if (widget.selecting ||
        keys.isControlPressed ||
        keys.isMetaPressed) {
      _c.toggleSelected(_m);
    } else {
      _c.open(_m);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final listColors = ListColors.of(context);
    final unread = !_m.flags.seen;
    final showCheckbox =
        widget.selecting || widget.checked || (_hovered && !_touch);
    final showActions = _hovered && !_touch && !widget.selecting;
    final background = widget.checked
        ? listColors.checked
        : widget.open
        ? listColors.selected
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.04)
        : Colors.transparent;

    final row = Semantics(
      selected: widget.open || widget.checked,
      label: [
        if (unread) 'Unread',
        if (_m.flags.flagged) 'Pinned',
        'From ${MailText.sender(_m)}',
        MailText.subject(_m),
        MailText.listDate(context, _m.receivedAt),
        if (_m.hasAttachments) 'Has attachments',
      ].join('. '),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Material(
            color: background,
            borderRadius: BorderRadius.circular(FmailTheme.radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _tap,
              onLongPress: () => _c.toggleSelected(_m),
              onSecondaryTapUp: (d) => _menu(d.globalPosition),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Unread: a dot beside the avatar, and bold text.
                    SizedBox(
                      width: 16,
                      height: 36,
                      child: unread
                          ? Center(
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: listColors.unreadDot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : null,
                    ),
                    SizedBox.square(
                      dimension: 36,
                      child: showCheckbox
                          ? Checkbox(
                              value: widget.checked,
                              onChanged: (_) => _c.toggleSelected(_m),
                              semanticLabel: 'Select',
                            )
                          : Avatar(
                              name: MailText.sender(_m),
                              address: _m.from?.address ?? '',
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _text(context, unread, showActions)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (!_touch || widget.selecting) return row;
    final canArchive =
        _c.archiveFor(_m)?.id != null && _c.archiveFor(_m)!.id != _m.mailboxId;
    return Dismissible(
      key: ValueKey('swipe-${_m.id}'),
      background: _SwipeBackground(
        alignment: Alignment.centerLeft,
        color: canArchive ? const Color(0xFF2E9E5B) : colors.primary,
        icon: canArchive
            ? Icons.archive_outlined
            : Icons.mark_email_read_outlined,
        label: canArchive ? 'Archive' : (_m.flags.seen ? 'Unread' : 'Read'),
      ),
      secondaryBackground: const _SwipeBackground(
        alignment: Alignment.centerRight,
        color: Color(0xFFD64545),
        icon: Icons.delete_outline,
        label: 'Delete',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          if (_c.isInTrash(_m)) return false; // forever needs the reader
          _c.delete([_m]);
          return true;
        }
        if (canArchive) {
          _c.archive([_m]);
          return true;
        }
        _c.toggleRead([_m]);
        return false;
      },
      child: row,
    );
  }

  /// Sender and date (or hover actions), subject, preview.
  Widget _text(BuildContext context, bool unread, bool showActions) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 22,
          child: Row(
            children: [
              if (_m.flags.flagged) ...[
                const Icon(Icons.push_pin, size: 14, color: MailText.pinColor),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  MailText.sender(_m),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (showActions)
                _QuickActions(message: _m, controller: _c)
              else ...[
                if (_m.hasAttachments)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.attach_file, size: 14, color: muted),
                  ),
                Text(
                  MailText.listDate(context, _m.receivedAt),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: unread ? colors.primary : muted,
                    fontWeight: unread ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ],
          ),
        ),
        Text(
          MailText.subject(_m),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
            height: 1.35,
          ),
        ),
        Text(
          _m.snippet ?? ' ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: muted,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Future<void> _menu(Offset at) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final archive = _c.archiveFor(_m);
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: () => _c.open(_m), child: const Text('Open')),
        PopupMenuItem(
          value: () => _c.togglePin([_m]),
          child: Text(_m.flags.flagged ? 'Unpin' : 'Pin'),
        ),
        PopupMenuItem(
          value: () => _c.toggleRead([_m]),
          child: Text(_m.flags.seen ? 'Mark as unread' : 'Mark as read'),
        ),
        if (archive != null && archive.id != _m.mailboxId)
          PopupMenuItem(
            value: () => _c.archive([_m]),
            child: const Text('Archive'),
          ),
        if (!_c.isInTrash(_m))
          PopupMenuItem(
            value: () => _c.delete([_m]),
            child: const Text('Move to Trash'),
          ),
        PopupMenuItem(
          value: () => _c.toggleSelected(_m),
          child: const Text('Select'),
        ),
      ],
    );
    action?.call();
  }
}

/// Archive, delete, pin and read buttons shown while hovering a row.
final class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.message, required this.controller});

  final StoredMessage message;
  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final archive = controller.archiveFor(message);
    Widget button(String tip, IconData icon, VoidCallback onPressed) =>
        IconButton(
          tooltip: tip,
          icon: Icon(icon, size: 18),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 30, height: 24),
          onPressed: onPressed,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (archive != null && archive.id != message.mailboxId)
          button(
            'Archive (E)',
            Icons.archive_outlined,
            () => controller.archive([message]),
          ),
        if (!controller.isInTrash(message))
          button(
            'Move to Trash (#)',
            Icons.delete_outline,
            () => controller.delete([message]),
          ),
        button(
          message.flags.flagged ? 'Unpin (S)' : 'Pin (S)',
          message.flags.flagged ? Icons.push_pin : Icons.push_pin_outlined,
          () => controller.togglePin([message]),
        ),
        button(
          message.flags.seen ? 'Mark as unread (U)' : 'Mark as read (U)',
          message.flags.seen
              ? Icons.mark_email_unread_outlined
              : Icons.mark_email_read_outlined,
          () => controller.toggleRead([message]),
        ),
      ],
    );
  }
}

final class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    color: color,
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
