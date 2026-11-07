// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mail_compose/mail_compose.dart';

import '../ui/citusmail_theme.dart';
import '../ui/follow_up_sheet.dart';
import '../ui/mail_shell.dart';
import '../ui/mail_text.dart';
import '../ui/send_later_sheet.dart';
import 'compose_controller.dart';
import 'recipient_field.dart';

/// The compose window. Closing it keeps the draft (in the Drafts folder);
/// it returns a [ComposeResult] to whoever opened it.
final class ComposePage extends StatefulWidget {
  const ComposePage({super.key, required this.controller});

  final ComposeController controller;

  /// From this window width the fields are a bounded column in the
  /// middle; narrower windows use the full width.
  static const wideWidth = 900.0;

  @override
  State<ComposePage> createState() => _ComposePageState();
}

final class _ComposePageState extends State<ComposePage> {
  late final _subject = TextEditingController(
    text: widget.controller.draft.subject,
  );
  late final _body = TextEditingController(text: widget.controller.draft.body);
  final _bodyFocus = FocusNode();

  ComposeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Replies start above the quote.
    _body.selection = const TextSelection.collapsed(offset: 0);
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop(_c.close());

  void _send() {
    final result = _c.send();
    if (result != null) Navigator.of(context).pop(result);
  }

  /// "Send later": choose a time, then it waits in the Outbox.
  Future<void> _sendLater() async {
    if (!_c.readyToSend()) return;
    final at = await SendLaterSheet.pick(context);
    if (at == null || !mounted) return;
    final result = _c.send(at: at);
    if (result != null) Navigator.of(context).pop(result);
  }

  /// "Remind me if no reply": when, or no reminder.
  Future<void> _chooseFollowUp() async {
    final picked = await FollowUpSheet.pick(context, current: _c.followUp?.at);
    if (picked == null || !mounted) return;
    _c.setFollowUp(picked);
  }

  Future<void> _discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this draft?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) Navigator.of(context).pop(_c.discard());
  }

  Future<void> _attach() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    final added = <DraftAttachment>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      added.add(
        DraftAttachment(
          fileName: file.name,
          mimeType: _mimeType(file.name),
          bytes: bytes,
        ),
      );
    }
    _c.addAttachments(added);
  }

  /// The type from the file name; unknown types are sent as plain data.
  static String _mimeType(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return const {
          'pdf': 'application/pdf',
          'txt': 'text/plain',
          'csv': 'text/csv',
          'png': 'image/png',
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'gif': 'image/gif',
          'webp': 'image/webp',
          'zip': 'application/zip',
          'doc': 'application/msword',
          'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          'xls': 'application/vnd.ms-excel',
          'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'ppt': 'application/vnd.ms-powerpoint',
          'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          'odt': 'application/vnd.oasis.opendocument.text',
          'ics': 'text/calendar',
        }[ext] ??
        'application/octet-stream';
  }

  static String _problem(ComposeProblem problem) => switch (problem) {
    ComposeProblem.noRecipients => 'Add at least one recipient.',
    ComposeProblem.invalidRecipient =>
      'Check the addresses: one of them isn\'t an email address.',
    ComposeProblem.attachmentsTooLarge =>
      'The attachments are too large to send (at most '
          '${MailText.size(OutgoingMessages.defaultMaxAttachmentBytes)}).',
    ComposeProblem.accountMissing => 'Choose the account to send from.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      // A plain surface, not a Scaffold: notices ("Sending…", "Saved to
      // Drafts") belong to the main screen, even while this one closes.
      child: Material(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) {
              final draft = _c.draft;
              final accounts = _c.accounts;
              // Phones: the actions (Send...) at the bottom, just above the
              // keyboard, within reach of the thumb.
              final phone =
                  MediaQuery.sizeOf(context).width < MailShell.mediumWidth;
              final width = MediaQuery.sizeOf(context).width;
              final actions = Padding(
                padding: phone
                    ? const EdgeInsets.fromLTRB(4, 8, 8, 4)
                    : const EdgeInsets.fromLTRB(8, 8, 12, 4),
                child: IconButtonTheme(
                  // Phones: slightly tighter buttons, so the toggles,
                  // Attach, Discard and Send fit in one row.
                  data: IconButtonThemeData(
                    style: phone
                        ? IconButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          )
                        : null,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close (keeps the draft)',
                        icon: const Icon(Icons.close),
                        onPressed: _close,
                      ),
                      const SizedBox(width: 4),
                      // Phones: no room for a title next to the buttons
                      // (the subject field shows it); Send keeps the edge.
                      if (phone)
                        const Spacer()
                      else
                        Expanded(
                          child: Text(
                            draft.subject.trim().isEmpty
                                ? 'New message'
                                : draft.subject,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: draft.requestReceipt
                            ? 'Read receipt requested (tap to cancel)'
                            : 'Ask for a read receipt',
                        isSelected: draft.requestReceipt,
                        icon: const Icon(Icons.mark_email_read_outlined),
                        selectedIcon: const Icon(Icons.mark_email_read),
                        onPressed: () =>
                            _c.setRequestReceipt(!draft.requestReceipt),
                      ),
                      IconButton(
                        key: const ValueKey('compose-follow-up'),
                        tooltip: switch (_c.followUp?.at) {
                          final at? =>
                            '${FollowUpSheet.remindsAt(context, at)} '
                                '(tap to change)',
                          null => 'Remind me if no reply',
                        },
                        isSelected: _c.followUp != null,
                        icon: const Icon(Icons.alarm_add_outlined),
                        selectedIcon: const Icon(Icons.alarm_on),
                        onPressed: _chooseFollowUp,
                      ),
                      IconButton(
                        tooltip: 'Attach files',
                        icon: const Icon(Icons.attach_file),
                        onPressed: _attach,
                      ),
                      IconButton(
                        tooltip: 'Discard',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _discard,
                      ),
                      const SizedBox(width: 8),
                      _SendButton(
                        onSend: _send,
                        onSendLater: _sendLater,
                        // The narrowest phones: the paper plane alone.
                        iconOnly: width < 380,
                      ),
                    ],
                  ),
                ),
              );
              // On a wide window the fields stay a readable column in the
              // middle; the toolbar keeps the full width.
              final fields = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (accounts.length > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: Text(
                              'From',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          DropdownButton<int>(
                            value: draft.accountId,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final a in accounts)
                                DropdownMenuItem(
                                  value: a.id,
                                  child: Text(a.email),
                                ),
                            ],
                            onChanged: (id) {
                              if (id != null) _c.setAccount(id);
                            },
                          ),
                        ],
                      ),
                    ),
                  RecipientField(
                    label: 'To',
                    list: _c.to,
                    suggest: _c.suggest,
                    autofocus: draft.to.isEmpty,
                    trailing: TextButton(
                      onPressed: _c.toggleCopies,
                      child: const Text('Cc Bcc'),
                    ),
                  ),
                  if (_c.showCopies) ...[
                    const Divider(indent: 16),
                    RecipientField(
                      label: 'Cc',
                      list: _c.cc,
                      suggest: _c.suggest,
                    ),
                    const Divider(indent: 16),
                    RecipientField(
                      label: 'Bcc',
                      list: _c.bcc,
                      suggest: _c.suggest,
                    ),
                  ],
                  const Divider(indent: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _subject,
                      onChanged: _c.setSubject,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => _bodyFocus.requestFocus(),
                      decoration: CitusmailTheme.bareField(hintText: 'Subject'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const Divider(),
                  if (_c.problems.isNotEmpty)
                    Container(
                      color: theme.colorScheme.errorContainer,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(
                        _c.problems.map(_problem).join(' '),
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  if (draft.attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final file in draft.attachments)
                            InputChip(
                              avatar: const Icon(Icons.attach_file, size: 18),
                              label: Text(
                                '${file.fileName} · ${MailText.size(file.bytes.length)}',
                              ),
                              onDeleted: () => _c.removeAttachment(file),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _body,
                        focusNode: _bodyFocus,
                        autofocus: draft.to.isNotEmpty,
                        onChanged: _c.setBody,
                        maxLines: null,
                        expands: true,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.45,
                        ),
                        decoration: CitusmailTheme.bareField(
                          hintText: 'Write your message',
                        ),
                      ),
                    ),
                  ),
                ],
              );
              return Padding(
                padding: EdgeInsets.only(
                  bottom: phone ? MediaQuery.viewInsetsOf(context).bottom : 0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!phone) ...[actions, const Divider()],
                    Expanded(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: width >= ComposePage.wideWidth
                                ? CitusmailTheme.writingWidth
                                : double.infinity,
                          ),
                          child: fields,
                        ),
                      ),
                    ),
                    if (phone) ...[const Divider(), actions],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Send, with "Send later" attached on its right (a split button): the
/// clock, or a long press on Send, offers the times.
final class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.onSend,
    required this.onSendLater,
    this.iconOnly = false,
  });

  final VoidCallback onSend;
  final VoidCallback onSendLater;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    const radius = Radius.circular(10);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (iconOnly)
          Tooltip(
            message: 'Send',
            child: FilledButton(
              onPressed: onSend,
              onLongPress: onSendLater,
              style: FilledButton.styleFrom(
                minimumSize: const Size(52, 44),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(left: radius),
                ),
              ),
              child: const Icon(Icons.send, size: 18),
            ),
          )
        else
          FilledButton.icon(
            onPressed: onSend,
            onLongPress: onSendLater,
            style: FilledButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.horizontal(left: radius),
              ),
            ),
            icon: const Icon(Icons.send, size: 18),
            label: const Text('Send'),
          ),
        const SizedBox(width: 2),
        Tooltip(
          message: 'Send later',
          child: FilledButton(
            key: const ValueKey('send-later'),
            onPressed: onSendLater,
            style: FilledButton.styleFrom(
              // As tall as Send (the theme's 44), narrower.
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.horizontal(right: radius),
              ),
            ),
            child: const Icon(Icons.schedule_send, size: 20),
          ),
        ),
      ],
    );
  }
}
