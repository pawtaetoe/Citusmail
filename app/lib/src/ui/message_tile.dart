// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'fmail_theme.dart';
import 'mail_text.dart';

/// One message in a list: unread dot, sender, time, subject and preview.
/// Right-click or long-press opens quick actions.
final class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.controller,
  });

  final StoredMessage message;
  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listColors = ListColors.of(context);
    final unread = !message.flags.seen;
    final selected = controller.selected?.id == message.id;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Material(
      color: selected ? listColors.selected : Colors.transparent,
      child: InkWell(
        onTap: () => controller.open(message),
        onLongPress: () => _menu(context, null),
        onSecondaryTapUp: (details) => _menu(context, details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 20,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: unread
                      ? Center(
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: listColors.unreadDot,
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (message.flags.flagged) ...[
                          const Icon(
                            Icons.push_pin,
                            size: 14,
                            color: Color(0xFFE5484D),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            MailText.sender(message),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (message.hasAttachments)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.attach_file,
                              size: 14,
                              color: muted,
                            ),
                          ),
                        Text(
                          MailText.listDate(context, message.receivedAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      MailText.subject(message),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: unread
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    if (message.snippet case final snippet?) ...[
                      const SizedBox(height: 2),
                      Text(
                        snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset? at) async {
    final box = context.findRenderObject()! as RenderBox;
    final position = at ?? box.localToGlobal(box.size.center(Offset.zero));
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final archive = controller.archiveFor(message);
    final action = await showMenu<void Function()>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: () => controller.togglePin(message),
          child: Text(message.flags.flagged ? 'Unpin' : 'Pin'),
        ),
        PopupMenuItem(
          value: () => controller.toggleRead(message),
          child: Text(message.flags.seen ? 'Mark as unread' : 'Mark as read'),
        ),
        if (archive != null && archive.id != message.mailboxId)
          PopupMenuItem(
            value: () => controller.archive(message),
            child: const Text('Archive'),
          ),
        if (!controller.isInTrash(message))
          PopupMenuItem(
            value: () => controller.delete(message),
            child: const Text('Move to Trash'),
          ),
      ],
    );
    action?.call();
  }
}
