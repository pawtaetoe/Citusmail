// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../../inbox/state/mail_controller.dart';
import 'reader_pane.dart';

/// An email read on its own page (a receipt, a booking's email): Back
/// returns to where it was opened from.
final class EmailPage extends StatefulWidget {
  const EmailPage({
    super.key,
    required this.controller,
    this.title = 'Receipt',
  });

  final MailController controller;
  final String title;

  /// Opens [message] on its own page; when it closes, the mail screen
  /// behind shows no message.
  static Future<void> open(
    BuildContext context,
    MailController controller,
    StoredMessage message, {
    String title = 'Receipt',
  }) async {
    await controller.open(message);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EmailPage(controller: controller, title: title),
      ),
    );
    controller.closeMessage();
  }

  @override
  State<EmailPage> createState() => _EmailPageState();
}

final class _EmailPageState extends State<EmailPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.reader.addListener(_closedElsewhere);
  }

  @override
  void dispose() {
    widget.controller.reader.removeListener(_closedElsewhere);
    super.dispose();
  }

  /// Archived, deleted or closed from its own actions: back to the list.
  void _closedElsewhere() {
    // Only while this page is on top: going back closes the message too.
    if (widget.controller.reader.value.message == null &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      top: false,
      child: ReaderPane(controller: widget.controller, toolbarAtBottom: true),
    ),
  );
}
