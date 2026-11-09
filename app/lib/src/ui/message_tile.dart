// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:background_clipboard/background_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'app_icons.dart';
import 'avatar.dart';
import 'badge.dart';
import 'citusmail_theme.dart';
import 'mail_text.dart';
import 'snooze_sheet.dart';

/// One message in a list: the sender's initials, sender, time, subject and
/// preview, with an unread dot. Every row has the same height, so long lists
/// scroll smoothly.
///
/// - Click opens; Ctrl/Cmd-click or the checkbox selects; Shift-click
///   selects a range.
/// - On hover (desktop): archive, delete, snooze, pin and read buttons.
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

  /// The preview line's size (the sender and subject are 14).
  static const previewSize = 13.0;

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
        ? theme.hoverColor
        : Colors.transparent;

    final row = Semantics(
      selected: widget.open || widget.checked,
      label: [
        if (unread) 'Unread',
        if (_m.flags.flagged) 'Pinned',
        'From ${MailText.sender(_m)}',
        MailText.subject(_m),
        if (_m.shownCode case final code?) 'Code $code',
        if (_c.snoozedUntil(_m) case final until?)
          'Snoozed until ${SnoozeSheet.describe(context, until)}'
        else if (_m.backFromSnooze)
          'Back from snooze ${MailText.listDate(context, _m.listedAt)}'
        else
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
            borderRadius: BorderRadius.circular(CitusmailTheme.radius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _tap,
              onLongPress: () => _c.toggleSelected(_m),
              onSecondaryTapUp: (d) => _menu(d.globalPosition),
              child: Stack(
                children: [
                  // The open row: a bar at its left, as in the sidebar,
                  // so it is marked by more than its tint.
                  if (widget.open)
                    Positioned(
                      key: const ValueKey('open-row-bar'),
                      left: 0,
                      top: 9,
                      bottom: 9,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: listColors.indicator,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  Padding(
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
                ],
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
        icon: canArchive ? AppIcons.archive : AppIcons.markRead,
        label: canArchive ? 'Archive' : (_m.flags.seen ? 'Unread' : 'Read'),
      ),
      secondaryBackground: const _SwipeBackground(
        alignment: Alignment.centerRight,
        color: Color(0xFFD64545),
        icon: AppIcons.delete,
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

  /// Sender and date (or hover actions), subject, preview. Unread: the
  /// sender and subject in semibold ink; read: the subject drops to
  /// regular weight and the muted colour, so unread mail stands out at a
  /// glance.
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
                const Icon(AppIcons.pinOn, size: 14, color: MailText.pinColor),
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
                    child: Icon(AppIcons.attachment, size: 14, color: muted),
                  ),
                if (_c.snoozedUntil(_m) case final until?) ...[
                  // In the Snoozed list: when it comes back.
                  Icon(AppIcons.snooze, size: 14, color: MailText.snoozeColor),
                  const SizedBox(width: 4),
                  Text(
                    SnoozeSheet.describe(context, until),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: MailText.snoozeColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else ...[
                  if (_m.backFromSnooze)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: AppBadge(
                        'Snoozed',
                        icon: AppIcons.snooze,
                        tint: MailText.snoozeColor,
                      ),
                    ),
                  Text(
                    MailText.listDate(context, _m.listedAt),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: unread ? colors.primary : muted,
                      fontWeight: unread ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        Text(
          MailText.subject(_m),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: unread ? colors.onSurface : muted,
            fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
            height: 1.35,
          ),
        ),
        if (_m.shownCode case final code?)
          _CodeLine(
            code: code,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: MessageTile.previewSize,
              height: 1.35,
            ),
          )
        else
          Text(
            _m.snippet ?? ' ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: muted,
              fontSize: MessageTile.previewSize,
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
        if (_c.snoozedUntil(_m) != null) ...[
          PopupMenuItem(
            value: () => SnoozeSheet.show(context, _c, [_m]),
            child: const Text('Change snooze time…'),
          ),
          PopupMenuItem(
            value: () => _c.unsnooze([_m]),
            child: const Text('Unsnooze'),
          ),
        ] else if (_c.canSnooze(_m))
          PopupMenuItem(
            value: () => SnoozeSheet.show(context, _c, [_m]),
            child: const Text('Snooze…'),
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

/// A verification code in place of the preview, so it can be read (and
/// copied with a tap) without opening the message. Exactly one text line
/// high, like the preview it replaces.
final class _CodeLine extends StatelessWidget {
  const _CodeLine({required this.code, required this.style});

  final String code;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = style?.fontSize ?? 12;
    return SizedBox(
      height: size * (style?.height ?? 1.35),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: 'Copy code',
          child: InkWell(
            key: ValueKey('copy-code-$code'),
            borderRadius: BorderRadius.circular(4),
            onTap: () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              // Marked sensitive, as from a notification: Android 13+
              // then keeps it out of its clipboard preview.
              await BackgroundClipboard.copy(
                code,
                label: 'Verification code',
                sensitive: true,
              );
              messenger
                ?..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text('Copied $code')));
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Code ',
                  style: style?.copyWith(color: colors.onSurfaceVariant),
                ),
                Text(
                  code,
                  style: style?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.copy, size: size, color: colors.primary),
              ],
            ),
          ),
        ),
      ),
    );
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
            AppIcons.archive,
            () => controller.archive([message]),
          ),
        if (!controller.isInTrash(message))
          button(
            'Move to Trash (#)',
            AppIcons.delete,
            () => controller.delete([message]),
          ),
        if (controller.snoozedUntil(message) != null)
          button(
            'Unsnooze',
            AppIcons.unsnooze,
            () => controller.unsnooze([message]),
          )
        else if (controller.canSnooze(message))
          button(
            'Snooze (B)',
            AppIcons.snooze,
            () => SnoozeSheet.show(context, controller, [message]),
          ),
        button(
          message.flags.flagged ? 'Unpin (S)' : 'Pin (S)',
          message.flags.flagged ? AppIcons.pinOn : AppIcons.pinOff,
          () => controller.togglePin([message]),
        ),
        button(
          message.flags.seen ? 'Mark as unread (U)' : 'Mark as read (U)',
          message.flags.seen ? AppIcons.markUnread : AppIcons.markRead,
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
