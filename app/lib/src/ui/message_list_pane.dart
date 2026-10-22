// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import '../mail/message_list_model.dart';
import 'fmail_theme.dart';
import 'folder_dialogs.dart';
import 'mail_text.dart';
import 'message_tile.dart';
import 'move_dialog.dart';

/// The middle pane: search and compose, the view's header (or the bulk
/// action bar while selecting), then the messages.
final class MessageListPane extends StatelessWidget {
  const MessageListPane({
    super.key,
    required this.controller,
    required this.onCompose,
    required this.searchFocus,
    this.leading,
  });

  final MailController controller;
  final VoidCallback onCompose;

  /// Focused by the "/" shortcut.
  final FocusNode searchFocus;

  /// A menu button on narrow screens, where the sidebar is a drawer.
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _TopBar(
        controller: controller,
        onCompose: onCompose,
        searchFocus: searchFocus,
        leading: leading,
      ),
      ValueListenableBuilder(
        valueListenable: controller.selection,
        builder: (context, selected, _) => selected.isEmpty
            ? _ViewHeader(controller: controller)
            : _SelectionBar(controller: controller, count: selected.length),
      ),
      const Divider(),
      Expanded(child: _Messages(controller: controller)),
    ],
  );
}

// ------------------------------------------------------------- top bar

final class _TopBar extends StatefulWidget {
  const _TopBar({
    required this.controller,
    required this.onCompose,
    required this.searchFocus,
    this.leading,
  });

  final MailController controller;
  final VoidCallback onCompose;
  final FocusNode searchFocus;
  final Widget? leading;

  @override
  State<_TopBar> createState() => _TopBarState();
}

final class _TopBarState extends State<_TopBar> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    child: Row(
      children: [
        ?widget.leading,
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: widget.controller.location,
            builder: (context, location, _) {
              if (location is! SearchLocation && _search.text.isNotEmpty) {
                _search.clear();
              }
              return SizedBox(
                height: 40,
                child: TextField(
                  controller: _search,
                  focusNode: widget.searchFocus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: widget.controller.search,
                  decoration: InputDecoration(
                    hintText: 'Search mail',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: location is SearchLocation
                        ? IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => widget.controller.search(''),
                          )
                        : null,
                    isDense: true,
                    filled: true,
                    fillColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'New message (C)',
          onPressed: widget.onCompose,
          icon: const Icon(Icons.edit_outlined),
        ),
      ],
    ),
  );
}

// --------------------------------------------------------------- header

/// Smart / Classic tabs for the inbox (or the view's title), and the sync
/// status line.
final class _ViewHeader extends StatelessWidget {
  const _ViewHeader({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.location,
    builder: (context, location, _) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 12, 4),
      child: Row(
        children: [
          Expanded(child: _title(context, location)),
          _StatusLine(controller: controller),
        ],
      ),
    ),
  );

  Widget _title(BuildContext context, MailLocation location) {
    final theme = Theme.of(context);
    final store = controller.services.store;
    if (location is InboxLocation) {
      return ValueListenableBuilder(
        valueListenable: controller.smartLayout,
        builder: (context, smart, _) => Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: true,
                label: Text('Smart'),
                tooltip: 'Sorted into sections',
              ),
              ButtonSegment(
                value: false,
                label: Text('Classic'),
                tooltip: 'One list, newest first',
              ),
            ],
            selected: {smart},
            onSelectionChanged: (s) => controller.setSmartLayout(s.single),
          ),
        ),
      );
    }
    final title = switch (location) {
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
      InboxLocation() => '',
    };
    final folder = location is FolderLocation
        ? store.mailboxes.byId(location.mailboxId)
        : null;
    return Row(
      children: [
        IconButton(
          tooltip: 'Back to Inbox',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => controller.goTo(const InboxLocation()),
        ),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (folder != null && controller.canHaveRules(folder))
          IconButton(
            tooltip: 'Folder rules',
            icon: const Icon(Icons.filter_alt_outlined),
            onPressed: () =>
                FolderRulesDialog.show(context, controller, folder),
          ),
      ],
    );
  }
}

/// "Updating…", "Offline", "Up to date": what sync is doing, always
/// visible (and a tap checks again).
final class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.status,
    builder: (context, status, _) {
      final colors = Theme.of(context).colorScheme;
      final (text, icon, color) = switch (status) {
        SyncRunning() => ('Updating…', null, colors.onSurfaceVariant),
        SyncProblem(kind: SyncFailureKind.network) => (
          'Offline',
          Icons.cloud_off,
          colors.onSurfaceVariant,
        ),
        SyncProblem(kind: SyncFailureKind.authentication, :final account) => (
          'Password not accepted ($account)',
          Icons.error_outline,
          colors.error,
        ),
        SyncProblem() => ('Can\'t update', Icons.error_outline, colors.error),
        SyncIdle(lastSynced: final at?) => (
          'Updated ${MailText.listDate(context, at)}',
          null,
          colors.onSurfaceVariant,
        ),
        SyncIdle() => ('', null, colors.onSurfaceVariant),
      };
      if (text.isEmpty) return const SizedBox.shrink();
      return Tooltip(
        message: 'Check for new mail',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: controller.syncNow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (status is SyncRunning)
                  const SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else if (icon != null)
                  Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Shown while messages are selected: what can be done to all of them.
final class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.controller, required this.count});

  final MailController controller;
  final int count;

  @override
  Widget build(BuildContext context) {
    final targets = controller.targets;
    final allRead = targets.every((m) => m.flags.seen);
    final allPinned = targets.every((m) => m.flags.flagged);
    final oneAccount = targets.map((m) => m.accountId).toSet().length == 1;
    return Container(
      color: Theme.of(context).colorScheme.primaryContainer
          .withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel selection (Esc)',
            icon: const Icon(Icons.close),
            onPressed: controller.clearSelection,
          ),
          Expanded(
            child: Text(
              '$count selected',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: 'Select all shown',
            icon: const Icon(Icons.select_all),
            onPressed: controller.selectAllVisible,
          ),
          IconButton(
            tooltip: 'Archive (E)',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () => controller.archive(targets),
          ),
          IconButton(
            tooltip: 'Move to Trash (#)',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => controller.delete(targets),
          ),
          IconButton(
            tooltip: allRead ? 'Mark as unread (U)' : 'Mark as read (U)',
            icon: Icon(
              allRead
                  ? Icons.mark_email_unread_outlined
                  : Icons.mark_email_read_outlined,
            ),
            onPressed: () => controller.toggleRead(targets),
          ),
          IconButton(
            tooltip: allPinned ? 'Unpin (S)' : 'Pin (S)',
            icon: Icon(allPinned ? Icons.push_pin : Icons.push_pin_outlined),
            onPressed: () => controller.togglePin(targets),
          ),
          if (oneAccount)
            IconButton(
              tooltip: 'Move to folder (V)',
              icon: const Icon(Icons.drive_file_move_outline),
              onPressed: () => MoveDialog.show(context, controller, targets),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- messages

final class _Messages extends StatefulWidget {
  const _Messages({required this.controller});

  final MailController controller;

  @override
  State<_Messages> createState() => _MessagesState();
}

final class _MessagesState extends State<_Messages> {
  final _scroll = ScrollController();

  MailController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final p = _scroll.position;
      if (!_c.list.showsSections && p.pixels > p.maxScrollExtent - 600) {
        _c.loadMore();
      }
    });
    _c.location.addListener(_toTop);
  }

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _c.location.removeListener(_toTop);
    _scroll.dispose();
    super.dispose();
  }

  Widget _tile(StoredMessage m) {
    final selection = _c.selection.value;
    return MessageTile(
      key: ValueKey(m.id),
      message: m,
      controller: _c,
      open: _c.selected?.id == m.id,
      checked: selection.contains(m.id),
      selecting: selection.isNotEmpty,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_c.list, _c.selection, _c.reader]),
    builder: (context, _) {
      final list = _c.list;
      if (list.location is OutboxLocation) return _outbox();
      final prototype = MessageTile(
        message: MessageTile.prototype,
        controller: _c,
        open: false,
        checked: false,
        selecting: false,
      );
      if (list.showsSections) {
        if (list.sections.isEmpty) {
          return const _Empty(Icons.inbox_outlined, 'Your inbox is empty.');
        }
        return Scrollbar(
          controller: _scroll,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              for (final section in list.sections)
                SliverMainAxisGroup(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _SectionHeader(section, _c),
                    ),
                    if (section.expanded) ...[
                      SliverPrototypeExtentList.builder(
                        prototypeItem: prototype,
                        itemCount: section.messages.length,
                        itemBuilder: (_, i) => _tile(section.messages[i]),
                      ),
                      if (section.hasMore)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(40, 4, 16, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () =>
                                    list.showMoreInSection(section.section),
                                child: Text(
                                  'Show more (${section.count.total - section.messages.length} more)',
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        );
      }
      final messages = list.messages;
      if (messages.isEmpty) {
        return _Empty(
          list.location is SearchLocation
              ? Icons.search_off
              : Icons.mail_outline,
          list.location is SearchLocation
              ? 'No messages found.'
              : 'No messages here.',
        );
      }
      return Scrollbar(
        controller: _scroll,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPrototypeExtentList.builder(
              prototypeItem: prototype,
              itemCount: messages.length,
              itemBuilder: (_, i) => _tile(messages[i]),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: list.loadingOlder
                      ? const CircularProgressIndicator()
                      : list.reachedEnd
                      ? Text(
                          'No older messages',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        )
                      : TextButton(
                          onPressed: _c.loadMore,
                          child: const Text('Load older messages'),
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _outbox() {
    final entries = _c.outbox;
    if (entries.isEmpty) {
      return const _Empty(Icons.outbox_outlined, 'Everything has been sent.');
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(indent: 16),
      itemBuilder: (context, i) =>
          _OutboxTile(entry: entries[i], controller: _c),
    );
  }
}

/// An accordion header that stays at the top while its section scrolls:
/// name, counts, the senders of a collapsed section, "mark all read".
final class _SectionHeader extends SliverPersistentHeaderDelegate {
  _SectionHeader(this.state, this.controller);

  final SectionState state;
  final MailController controller;

  static const height = 56.0;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  bool shouldRebuild(_SectionHeader old) => true;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final section = state.section;
    final count = state.count;
    final senders = {
      for (final m in state.messages.take(MessageListModel.collapsedPreview))
        MailText.sender(m),
    }.join(', ');
    final total = count.total == 1 ? '1 message' : '${count.total} messages';
    // Unread is on the badge; collapsed sections say who wrote.
    final summary = state.expanded || senders.isEmpty ? total : senders;
    return Material(
      color: ListColors.of(context).sectionBackground,
      elevation: overlapsContent ? 1 : 0,
      child: Semantics(
        button: true,
        expanded: state.expanded,
        label:
            '${MailText.section(section)}, ${count.total} messages, ${count.unread} unread',
        child: InkWell(
          onTap: () => controller.list.toggleSection(section),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: state.expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(
                    Icons.chevron_right,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  MailText.sectionIcon(section),
                  size: 18,
                  color: MailText.sectionColor(section, colors),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            MailText.section(section),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (count.unread > 0) ...[
                            const SizedBox(width: 8),
                            _Badge(count.unread),
                          ],
                        ],
                      ),
                      Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (count.unread > 0)
                  IconButton(
                    tooltip: 'Mark all ${MailText.section(section)} as read',
                    icon: const Icon(Icons.done_all, size: 20),
                    color: colors.onSurfaceVariant,
                    onPressed: () => controller.markSectionRead(section),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _Badge extends StatelessWidget {
  const _Badge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      count > 999 ? '999+' : '$count',
      style: TextStyle(
        color: Theme.of(context).colorScheme.onPrimary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

final class _Empty extends StatelessWidget {
  const _Empty(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: colors.outlineVariant),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

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
