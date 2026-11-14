// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_store/mail_store.dart' show SignOff;

import '../ui/app_icons.dart';
import '../ui/citusmail_theme.dart';
import '../ui/follow_up_sheet.dart';
import '../ui/mail_shell.dart';
import '../ui/mail_text.dart';
import '../ui/send_later_sheet.dart';
import '../ui/sign_offs_page.dart';
import 'compose_controller.dart';
import 'recipient_field.dart';
import 'writing_sheet.dart';

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
  late final _quote = TextEditingController(
    text: widget.controller.draft.quote,
  );
  final _bodyFocus = FocusNode();
  final _signOffMenu = GlobalKey<PopupMenuButtonState<Object>>();

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
    _quote.dispose();
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

  /// "Write a new sign-off…": kept in the list unless "Save for later"
  /// is unticked.
  Future<void> _writeSignOff() async {
    final written = await SignOffEditor.show(context, offerSaveForLater: true);
    if (written == null || !mounted) return;
    _c.writeSignOff(
      text: written.text,
      name: written.name,
      separator: written.separator,
      save: written.save,
    );
  }

  Future<void> _manageSignOffs() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SignOffsPage(services: _c.services),
      ),
    );
    if (mounted) _c.signOffsChanged();
  }

  void _pickSignOff(Object picked) => switch (picked) {
    final SignOff s => _c.chooseSignOff(s),
    _SignOffAction.none => _c.chooseSignOff(null),
    _SignOffAction.write => _writeSignOff(),
    _SignOffAction.manage => _manageSignOffs(),
    _ => null,
  };

  /// "Write with AI": asks once whether the feature may send to its
  /// provider, then offers a drafted reply or a rewrite. Only the body
  /// ever changes, and only when the user picks Replace or Insert below.
  Future<void> _writeWithAi() async {
    final ai = _c.services.ai;
    final provider = await ai.providerFor(AiFeatures.writing.id);
    if (!mounted) return;
    if (provider == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Writing help isn\'t ready'),
          content: const Text(
            'Its provider or key is missing. Check Settings, AI assistant.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    if (provider.needsConfirmation) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Send to ${provider.recipient}?'),
          content: Text(
            'Each time you ask, writing help sends '
            '${AiFeatures.writing.sends} to ${provider.recipient}, with your '
            'key. Nothing else from your mailbox is sent, and nothing '
            'changes in your email until you choose to use the text.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      provider.confirm();
    }
    final choice = await WritingSheet.show(
      context,
      provider: provider,
      assistant: _c.writing,
      body: _body.text,
      source: _c.replySource(),
      forward: _c.forwards,
      userName: _c.userName,
      signOff: _c.signOff?.text,
    );
    if (choice == null || !mounted) return;
    final next = _c.useWriting(choice.text, replace: choice.replace);
    _body.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  void _undoWriting() {
    final before = _c.undoWriting();
    if (before == null) return;
    _body.value = TextEditingValue(
      text: before,
      selection: TextSelection.collapsed(offset: before.length),
    );
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
            // The AI's switch too: "Write with AI" shows only while on.
            listenable: Listenable.merge([_c, _c.services.ai.changes]),
            builder: (context, _) {
              final draft = _c.draft;
              final accounts = _c.accounts;
              final writing = _c.services.ai.isOn(AiFeatures.writing.id);
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
                        icon: const Icon(AppIcons.close),
                        onPressed: _close,
                      ),
                      if (!phone) const SizedBox(width: 4),
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
                      _Toggle(
                        tooltip: draft.requestReceipt
                            ? 'Read receipt requested (tap to cancel)'
                            : 'Ask for a read receipt',
                        label: 'Receipt',
                        labelled: !phone,
                        selected: draft.requestReceipt,
                        icon: AppIcons.receipt,
                        selectedIcon: AppIcons.receiptOn,
                        onPressed: () =>
                            _c.setRequestReceipt(!draft.requestReceipt),
                      ),
                      _Toggle(
                        key: const ValueKey('compose-follow-up'),
                        tooltip: switch (_c.followUp?.at) {
                          final at? =>
                            '${FollowUpSheet.remindsAt(context, at)} '
                                '(tap to change)',
                          null => 'Remind me if no reply',
                        },
                        label: 'Remind me',
                        labelled: !phone,
                        selected: _c.followUp != null,
                        icon: AppIcons.remind,
                        selectedIcon: AppIcons.remindOn,
                        onPressed: _chooseFollowUp,
                      ),
                      if (writing)
                        _Toggle(
                          key: const ValueKey('compose-write-with-ai'),
                          tooltip: 'Write with AI',
                          label: 'Write with AI',
                          labelled: !phone,
                          selected: false,
                          icon: AppIcons.writeWithAi,
                          selectedIcon: AppIcons.writeWithAi,
                          onPressed: _writeWithAi,
                        ),
                      IconButton(
                        tooltip: 'Attach files',
                        icon: const Icon(AppIcons.attachment),
                        onPressed: _attach,
                      ),
                      IconButton(
                        tooltip: 'Discard',
                        icon: const Icon(AppIcons.delete),
                        onPressed: _discard,
                      ),
                      SizedBox(width: phone ? 2 : 8),
                      _SendButton(
                        onSend: _send,
                        onSendLater: _sendLater,
                        // The narrowest phones: the paper plane alone
                        // (wider ones too with "Write with AI").
                        iconOnly: width < (writing ? 430 : 380),
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
                      child: const Text('Cc · Bcc'),
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
                  if (_c.canUndoWriting)
                    Container(
                      key: const ValueKey('writing-undo'),
                      color: theme.colorScheme.secondaryContainer,
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Written with AI. Read it through before '
                              'sending.',
                              style: TextStyle(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _undoWriting,
                            child: const Text('Undo'),
                          ),
                          IconButton(
                            tooltip: 'Keep it',
                            icon: const Icon(AppIcons.close, size: 18),
                            onPressed: _c.keepWriting,
                          ),
                        ],
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
                              avatar: const Icon(AppIcons.attachment, size: 18),
                              label: Text(
                                '${file.fileName} · ${MailText.size(file.bytes.length)}',
                              ),
                              onDeleted: () => _c.removeAttachment(file),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    // What the user writes, then the sign-off, then the
                    // quote of a reply; the space below focuses the text.
                    child: CustomScrollView(
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          sliver: SliverList.list(
                            children: [
                              TextField(
                                controller: _body,
                                focusNode: _bodyFocus,
                                autofocus: draft.to.isNotEmpty,
                                onChanged: _c.setBody,
                                minLines: 4,
                                maxLines: null,
                                keyboardType: TextInputType.multiline,
                                textAlignVertical: TextAlignVertical.top,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  height: 1.45,
                                ),
                                decoration: CitusmailTheme.bareField(
                                  hintText: 'Write your message',
                                ),
                              ),
                              _SignOffBlock(
                                menuKey: _signOffMenu,
                                signOff: draft.signOff,
                                signOffs: _c.signOffs,
                                onSelected: _pickSignOff,
                              ),
                              if (_quote.text.isNotEmpty)
                                TextField(
                                  key: const ValueKey('compose-quote'),
                                  controller: _quote,
                                  onChanged: _c.setQuote,
                                  maxLines: null,
                                  keyboardType: TextInputType.multiline,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    height: 1.45,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  decoration: CitusmailTheme.bareField(),
                                ),
                            ],
                          ),
                        ),
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _bodyFocus.requestFocus,
                            child: const SizedBox(height: 48),
                          ),
                        ),
                      ],
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

enum _SignOffAction { none, write, manage }

/// The sign-off at the end of the message, marked as such: a small
/// button above it says which it is and offers the others, none, a new
/// one, or managing the list.
final class _SignOffBlock extends StatelessWidget {
  const _SignOffBlock({
    required this.menuKey,
    required this.signOff,
    required this.signOffs,
    required this.onSelected,
  });

  final GlobalKey<PopupMenuButtonState<Object>> menuKey;
  final SignOff? signOff;
  final List<SignOff> signOffs;
  final ValueChanged<Object> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final current = signOff;
    final label = switch (current) {
      null => signOffs.isEmpty ? 'Add a sign-off' : 'No sign-off',
      final s when !s.isSaved => 'Sign-off: this email only',
      final s => 'Sign-off: ${s.name}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: CitusSpace.s),
        PopupMenuButton<Object>(
          key: menuKey,
          tooltip: 'Choose the sign-off (signature)',
          onSelected: onSelected,
          itemBuilder: (_) => [
            for (final s in signOffs)
              CheckedPopupMenuItem<Object>(
                value: s,
                checked: current?.id == s.id,
                child: Text(s.name),
              ),
            CheckedPopupMenuItem<Object>(
              value: _SignOffAction.none,
              checked: current == null,
              child: const Text('None'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<Object>(
              value: _SignOffAction.write,
              child: Text('Write a new sign-off…'),
            ),
            const PopupMenuItem<Object>(
              value: _SignOffAction.manage,
              child: Text('Manage sign-offs…'),
            ),
          ],
          child: Container(
            key: const ValueKey('compose-sign-off'),
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  AppIcons.signOff,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                Icon(AppIcons.dropDown, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
        if (current != null)
          GestureDetector(
            onTap: () => menuKey.currentState?.showButtonMenu(),
            child: Container(
              key: const ValueKey('compose-sign-off-text'),
              margin: const EdgeInsets.only(top: CitusSpace.s, bottom: 4),
              padding: const EdgeInsets.only(left: CitusSpace.m),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: colors.outlineVariant, width: 2),
                ),
              ),
              child: Text(
                current.block,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
              ),
            ),
          ),
        const SizedBox(height: CitusSpace.m),
      ],
    );
  }
}

/// A setting of the message that is on or off (a read receipt, a
/// reminder): an icon button on phones, a labelled button where there is
/// room, filled in while it is on.
final class _Toggle extends StatelessWidget {
  const _Toggle({
    super.key,
    required this.tooltip,
    required this.label,
    required this.labelled,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.onPressed,
  });

  final String tooltip;
  final String label;
  final bool labelled;
  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!labelled) {
      return IconButton(
        tooltip: tooltip,
        isSelected: selected,
        icon: Icon(icon),
        selectedIcon: Icon(selectedIcon),
        onPressed: onPressed,
      );
    }
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        style: selected
            ? TextButton.styleFrom(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
              )
            : TextButton.styleFrom(foregroundColor: colors.onSurfaceVariant),
        onPressed: onPressed,
        icon: Icon(selected ? selectedIcon : icon, size: 20),
        label: Text(label),
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
              child: const Icon(AppIcons.send, size: 18),
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
            icon: const Icon(AppIcons.send, size: 18),
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
            child: const Icon(AppIcons.sendLater, size: 20),
          ),
        ),
      ],
    );
  }
}
