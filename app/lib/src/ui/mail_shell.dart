// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../background/background_mail.dart';
import '../compose/compose_launcher.dart';
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import '../services/app_services.dart';
import '../services/mail_notifier.dart';
import '../services/new_mail_announcer.dart';
import 'message_list_pane.dart';
import 'reader_pane.dart';
import 'sidebar.dart';

/// The main screen, laid out for the space available:
///
/// - wide (desktop): sidebar, message list and reader side by side;
/// - medium (tablet, narrow window): list and reader, sidebar in a drawer;
/// - narrow (phone): the list, or the open message, one at a time.
final class MailShell extends StatefulWidget {
  const MailShell({
    super.key,
    required this.services,
    required this.onAddAccount,
    required this.onAccountsChanged,
    this.notifications = true,
  });

  final AppServices services;
  final VoidCallback onAddAccount;
  final VoidCallback onAccountsChanged;

  /// Off in tests, which must not reach the desktop's notification service.
  final bool notifications;

  static const wideWidth = 1100.0;
  static const mediumWidth = 720.0;

  @override
  State<MailShell> createState() => _MailShellState();
}

final class _MailShellState extends State<MailShell> {
  late final MailController _controller = MailController(widget.services);
  final _scaffold = GlobalKey<ScaffoldState>();
  NewMailAnnouncer? _announcer;

  @override
  void initState() {
    super.initState();
    _controller.onCompose = (draft) =>
        unawaited(ComposeLauncher.open(context, widget.services, draft));
    _controller.onNotice = (String text) =>
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(text)));
    unawaited(widget.services.worker.start().catchError((Object _) {}));
    if (widget.notifications) {
      unawaited(_startNotifications());
      // Android: background checks while the app is closed.
      unawaited(_startBackground());
    }
  }

  Future<void> _startBackground() async {
    try {
      // The periodic check is scheduled by Android itself at launch.
      if (widget.services.settings.instantMail) {
        await BackgroundMail.setInstant(true);
      }
    } on Object {
      // Not fatal: mail still syncs while the app is open.
    }
  }

  Future<void> _startNotifications() async {
    final notifier = await MailNotifier.create(
      onOpen: (id) {
        final message = widget.services.store.messages.byId(id);
        if (message != null && mounted) unawaited(_controller.open(message));
      },
    );
    if (!mounted) return;
    _announcer = NewMailAnnouncer(widget.services, notifier);
    if (widget.services.settings.notifications) {
      await notifier?.requestPermission();
    }
  }

  @override
  void dispose() {
    unawaited(_announcer?.dispose());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _removeAccount(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${account.email}?'),
        content: const Text(
          'Its mail is removed from this device and its password from the keychain. '
          'Nothing is deleted on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.services.removeAccount(account);
    _controller.goTo(const InboxLocation());
    widget.onAccountsChanged();
  }

  void _compose() => _controller.compose();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        Widget sidebar({bool inDrawer = false}) => Sidebar(
          controller: _controller,
          onAddAccount: widget.onAddAccount,
          onRemoveAccount: _removeAccount,
          onNavigated: inDrawer
              ? () => _scaffold.currentState?.closeDrawer()
              : null,
        );
        final menu = width >= MailShell.wideWidth
            ? null
            : IconButton(
                tooltip: 'Folders',
                icon: const Icon(Icons.menu),
                onPressed: () => _scaffold.currentState?.openDrawer(),
              );
        final list = MessageListPane(
          controller: _controller,
          onCompose: _compose,
          leading: menu,
        );

        final Widget body;
        if (width >= MailShell.wideWidth) {
          body = Row(
            children: [
              SizedBox(width: 250, child: sidebar()),
              SizedBox(width: 400, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: ReaderPane(controller: _controller)),
            ],
          );
        } else if (width >= MailShell.mediumWidth) {
          body = Row(
            children: [
              SizedBox(width: (width * 0.42).clamp(320, 400), child: list),
              const VerticalDivider(width: 1),
              Expanded(child: ReaderPane(controller: _controller)),
            ],
          );
        } else {
          final open = _controller.selected != null;
          body = PopScope(
            canPop: !open,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _controller.closeMessage();
            },
            child: open
                ? ReaderPane(controller: _controller, showBack: true)
                : list,
          );
        }
        return Scaffold(
          key: _scaffold,
          drawer: width >= MailShell.wideWidth
              ? null
              : Drawer(width: 290, child: sidebar(inDrawer: true)),
          body: SafeArea(left: false, child: body),
        );
      },
    ),
  );
}
