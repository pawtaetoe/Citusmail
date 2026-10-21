// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'fmail_theme.dart';
import 'mail_text.dart';
import 'message_tile.dart';

/// The middle pane: search, Smart / Classic switch, and the messages.
final class MessageListPane extends StatefulWidget {
  const MessageListPane({
    super.key,
    required this.controller,
    required this.onCompose,
    this.leading,
  });

  final MailController controller;
  final VoidCallback onCompose;

  /// A menu button on narrow screens, where the sidebar is a drawer.
  final Widget? leading;

  @override
  State<MessageListPane> createState() => _MessageListPaneState();
}

final class _MessageListPaneState extends State<MessageListPane> {
  final _search = TextEditingController();
  final _scroll = ScrollController();

  MailController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final position = _scroll.position;
      if (position.pixels > position.maxScrollExtent - 400) {
        _controller.loadMore();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = _controller.location;
    if (location is! SearchLocation && _search.text.isNotEmpty) _search.clear();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              ?widget.leading,
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _controller.search,
                    decoration: InputDecoration(
                      hintText: 'Search',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: location is SearchLocation
                          ? IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                _search.clear();
                                _controller.search('');
                              },
                            )
                          : null,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: 'New message',
                onPressed: widget.onCompose,
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
        ),
        _Header(controller: _controller),
        const Divider(),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _body(BuildContext context) {
    if (_controller.location is OutboxLocation) {
      final entries = _controller.outbox;
      if (entries.isEmpty) return const _Empty('Everything has been sent.');
      return ListView.separated(
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(indent: 16),
        itemBuilder: (context, i) =>
            _OutboxTile(entry: entries[i], controller: _controller),
      );
    }
    if (_controller.showsSections) {
      final sections = _controller.sections;
      if (sections.isEmpty) return const _Empty('No mail in your inbox yet.');
      return ListView(
        children: [
          for (final preview in sections)
            _Section(preview: preview, controller: _controller),
        ],
      );
    }
    final messages = _controller.messages;
    if (messages.isEmpty) {
      return _Empty(
        _controller.location is SearchLocation
            ? 'No messages found.'
            : 'No messages here.',
      );
    }
    return ListView.separated(
      controller: _scroll,
      itemCount: messages.length + 1,
      separatorBuilder: (_, _) => const Divider(indent: 28),
      itemBuilder: (context, index) {
        if (index < messages.length) {
          return MessageTile(message: messages[index], controller: _controller);
        }
        if (_controller.loadingOlder) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (!_controller.canLoadMore) return const SizedBox(height: 24);
        return Center(
          child: TextButton(
            onPressed: _controller.loadMore,
            child: const Text('Load older messages'),
          ),
        );
      },
    );
  }
}

/// Smart / Classic tabs for the inbox; a title elsewhere.
final class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final location = controller.location;
    final store = controller.services.store;
    final title = switch (location) {
      InboxLocation() => null,
      SectionLocation(:final section) => MailText.section(section),
      FolderLocation(:final mailboxId) => switch (store.mailboxes.byId(
        mailboxId,
      )) {
        final mailbox? => MailText.folder(mailbox),
        null => '',
      },
      PinsLocation() => 'Pins',
      OutboxLocation() => 'Outbox',
      SearchLocation(:final text) => 'Results for "$text"',
    };
    if (title != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
        child: Row(
          children: [
            if (location is SectionLocation)
              IconButton(
                tooltip: 'Back to inbox',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => controller.goTo(
                  InboxLocation(accountId: location.accountId),
                ),
              )
            else
              const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }
    Widget tab(String label, bool smart) {
      final active = controller.smartLayout == smart;
      return InkWell(
        onTap: () => controller.setSmartLayout(smart),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(children: [tab('Smart', true), tab('Classic', false)]),
    );
  }
}

/// One Smart Inbox section: header with counts, newest messages, and
/// "Show all" when there are more.
final class _Section extends StatelessWidget {
  const _Section({required this.preview, required this.controller});

  final SectionPreview preview;
  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final section = preview.section;
    final more = preview.count.total - preview.messages.length;
    final location = controller.location;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: ListColors.of(context).sectionBackground,
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                MailText.sectionIcon(section),
                size: 18,
                color: MailText.sectionColor(section, colors),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: () => controller.goTo(
                    SectionLocation(section, accountId: location.accountId),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        MailText.section(section),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        preview.count.unread > 0
                            ? '${preview.count.unread} unread'
                            : preview.count.total == 1
                            ? '1 message'
                            : '${preview.count.total} messages',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (preview.count.unread > 0)
                IconButton(
                  tooltip: 'Mark all as read',
                  icon: const Icon(Icons.check_circle_outline),
                  color: colors.onSurfaceVariant,
                  onPressed: () => controller.markSectionRead(section),
                ),
            ],
          ),
        ),
        for (final message in preview.messages) ...[
          MessageTile(message: message, controller: controller),
          const Divider(indent: 28),
        ],
        if (more > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 20),
              child: TextButton(
                onPressed: () => controller.goTo(
                  SectionLocation(section, accountId: location.accountId),
                ),
                child: Text('Show all ${preview.count.total}'),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

final class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

/// A message waiting in the outbox, with what is happening to it.
final class _OutboxTile extends StatelessWidget {
  const _OutboxTile({required this.entry, required this.controller});

  final OutboxEntry entry;
  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headers = entry.data == null
        ? null
        : const MimeParser().parse(entry.data!);
    final failed = entry.state == OutboxState.failed;
    final status = switch (entry) {
      _ when failed =>
        'Not sent: ${entry.lastError ?? 'the server refused it'}',
      _ when entry.lastError != null => 'Will try again: ${entry.lastError}',
      _ when entry.notBefore.isAfter(DateTime.now()) => 'Sending shortly…',
      _ => 'Waiting to send…',
    };
    return ListTile(
      leading: Icon(
        failed ? Icons.error_outline : Icons.schedule_send,
        color: failed ? theme.colorScheme.error : theme.colorScheme.primary,
      ),
      title: Text(
        headers?.subject?.trim().isNotEmpty == true
            ? headers!.subject!
            : '(no subject)',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (headers != null && headers.to.isNotEmpty)
            'To ${headers.to.map((a) => a.address).join(', ')}',
          status,
        ].join('\n'),
        style: TextStyle(color: failed ? theme.colorScheme.error : null),
      ),
      isThreeLine: true,
      trailing: failed
          ? Wrap(
              children: [
                IconButton(
                  tooltip: 'Try again',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => controller.retrySend(entry),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => controller.discardSend(entry),
                ),
              ],
            )
          : null,
    );
  }
}
