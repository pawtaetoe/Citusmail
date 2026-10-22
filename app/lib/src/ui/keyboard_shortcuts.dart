// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mail/mail_controller.dart';
import 'move_dialog.dart';

/// One shortcut, for the keys and for the help sheet.
final class _Shortcut {
  const _Shortcut(this.keys, this.description);

  final String keys;
  final String description;
}

/// Mail keyboard shortcuts (the common Gmail-style keys). They never fire
/// while typing in a text field; `?` shows them all.
final class MailKeyboardShortcuts extends StatelessWidget {
  const MailKeyboardShortcuts({
    super.key,
    required this.controller,
    required this.searchFocus,
    required this.focusNode,
    required this.child,
  });

  final MailController controller;
  final FocusNode searchFocus;
  final FocusNode focusNode;
  final Widget child;

  static const shortcuts = [
    _Shortcut('J / K', 'Next / previous message'),
    _Shortcut('Enter', 'Open the first message'),
    _Shortcut('Esc', 'Close the message, or cancel the selection'),
    _Shortcut('E', 'Archive'),
    _Shortcut('# or Delete', 'Move to Trash'),
    _Shortcut('V', 'Move to folder'),
    _Shortcut('S', 'Pin or unpin'),
    _Shortcut('U', 'Mark as read or unread'),
    _Shortcut('X', 'Select the open message'),
    _Shortcut('R / A / F', 'Reply / Reply all / Forward'),
    _Shortcut('C', 'New message'),
    _Shortcut('/', 'Search'),
    _Shortcut('?', 'These shortcuts'),
  ];

  /// Whether a text field has the keyboard (then keys are text).
  static bool _typing() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_typing()) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final c = controller;
    final targets = c.targets;
    final reader = c.reader.value;
    final handled = switch ((event.logicalKey, event.character)) {
      (LogicalKeyboardKey.escape, _) => () {
        if (c.selecting) {
          c.clearSelection();
        } else {
          c.closeMessage();
        }
      },
      (LogicalKeyboardKey.enter, _) when c.selected == null =>
        () => c.openNext(),
      (LogicalKeyboardKey.delete, _) => _delete,
      (_, 'j') => () => c.openNext(),
      (_, 'k') => () => c.openNext(previous: true),
      (_, 'e') => () => c.archive(targets),
      (_, '#') => _delete,
      (_, 's') => () => c.togglePin(targets),
      (_, 'u') => () => c.toggleRead(targets),
      (_, 'v') => () => MoveDialog.show(context, c, targets),
      (_, 'x') => () {
        final open = c.selected;
        if (open != null) c.toggleSelected(open);
      },
      (_, 'r') when reader is ReaderReady => () => c.reply(reader),
      (_, 'a') when reader is ReaderReady => () => c.replyAll(reader),
      (_, 'f') when reader is ReaderReady => () => c.forward(reader),
      (_, 'c') => c.compose,
      (_, '/') => searchFocus.requestFocus,
      (_, '?') => () => showShortcuts(context),
      _ => null,
    };
    if (handled == null) return KeyEventResult.ignored;
    handled();
    return KeyEventResult.handled;
  }

  /// Delete by keyboard never deletes for good (that needs the button and
  /// a confirmation).
  void _delete() {
    final messages = controller.targets;
    if (messages.isEmpty || messages.every(controller.isInTrash)) return;
    controller.delete(messages);
  }

  static Future<void> showShortcuts(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in shortcuts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        s.keys,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(child: Text(s.description)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    autofocus: true,
    onKeyEvent: (_, event) => _onKey(context, event),
    child: child,
  );
}
