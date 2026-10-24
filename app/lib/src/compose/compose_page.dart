// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mail_compose/mail_compose.dart';

import '../ui/fmail_theme.dart';
import '../ui/mail_text.dart';
import 'compose_controller.dart';
import 'recipient_field.dart';

/// The compose window. Closing it keeps the draft (in the Drafts folder);
/// it returns a [ComposeResult] to whoever opened it.
final class ComposePage extends StatefulWidget {
  const ComposePage({super.key, required this.controller});

  final ComposeController controller;

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
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Close (keeps the draft)',
                          icon: const Icon(Icons.close),
                          onPressed: _close,
                        ),
                        const SizedBox(width: 4),
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
                        FilledButton.icon(
                          onPressed: _send,
                          icon: const Icon(Icons.send, size: 18),
                          label: const Text('Send'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
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
                      decoration: FmailTheme.bareField(hintText: 'Subject'),
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
                        decoration: FmailTheme.bareField(
                          hintText: 'Write your message',
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
