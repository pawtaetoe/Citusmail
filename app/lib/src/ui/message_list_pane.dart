// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import '../mail/message_list_model.dart';
import '../mail/send_later_times.dart';
import 'ai_tidy_sheet.dart';
import 'app_icons.dart';
import 'attachments_page.dart';
import 'citusmail_theme.dart';
import 'code_cleanup_banner.dart';
import 'empty_state.dart';
import 'folder_dialogs.dart';
import 'follow_ups_list.dart';
import 'mail_text.dart';
import 'message_tile.dart';
import 'move_dialog.dart';
import 'new_since_away_section.dart';
import 'screener_page.dart';
import 'send_later_sheet.dart';
import 'skeleton_rows.dart';
import 'snooze_sheet.dart';
import 'whats_new.dart';

/// The middle pane: search and compose, the view's header (or the bulk
/// action bar while selecting), then the messages.
final class MessageListPane extends StatelessWidget {
  const MessageListPane({
    super.key,
    required this.controller,
    required this.onCompose,
    required this.searchFocus,
    this.leading,
    this.controlsAtBottom = false,
  });

  final MailController controller;

  /// Phones: the search bar and the selection actions are in
  /// [MessageListControls] at the bottom of the screen, within reach of the
  /// thumb; only the view's title stays on top.
  final bool controlsAtBottom;

  /// Null when the sidebar has the "New message" button.
  final VoidCallback? onCompose;

  /// Focused by the "/" shortcut.
  final FocusNode searchFocus;

  /// A menu button on narrow screens, where the sidebar is a drawer.
  final Widget? leading;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: ListColors.of(context).background,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controlsAtBottom)
          SizedBox(height: 48, child: _ViewHeader(controller: controller))
        else ...[
          _TopBar(
            controller: controller,
            onCompose: onCompose,
            searchFocus: searchFocus,
            leading: leading,
          ),
          SizedBox(
            height: 48,
            child: ValueListenableBuilder(
              valueListenable: controller.selection,
              builder: (context, selected, _) => selected.isEmpty
                  ? _ViewHeader(controller: controller)
                  : _SelectionBar(
                      controller: controller,
                      count: selected.length,
                      withTidy: true,
                    ),
            ),
          ),
        ],
        // After an update: what is new, once.
        WhatsNewCard(controller: controller),
        Expanded(child: _Messages(controller: controller)),
      ],
    ),
  );
}

/// The list's controls at the bottom of a phone screen: menu, search and
/// New message, or the actions for selected messages.
final class MessageListControls extends StatelessWidget {
  const MessageListControls({
    super.key,
    required this.controller,
    required this.onCompose,
    required this.searchFocus,
    required this.leading,
  });

  final MailController controller;
  final VoidCallback onCompose;
  final FocusNode searchFocus;
  final Widget leading;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.selection,
    builder: (context, selected, _) => selected.isEmpty
        ? _TopBar(
            controller: controller,
            onCompose: onCompose,
            searchFocus: searchFocus,
            leading: leading,
            padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          )
        : SizedBox(
            height: 60,
            child: _SelectionBar(
              controller: controller,
              count: selected.length,
            ),
          ),
  );
}

// ------------------------------------------------------------- top bar

final class _TopBar extends StatefulWidget {
  const _TopBar({
    required this.controller,
    required this.onCompose,
    required this.searchFocus,
    this.leading,
    this.padding = const EdgeInsets.fromLTRB(12, 12, 12, 4),
  });

  final MailController controller;
  final VoidCallback? onCompose;
  final FocusNode searchFocus;
  final Widget? leading;
  final EdgeInsets padding;

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

  /// Attachments from all your mail, with their own search.
  void _openFiles(BuildContext context) {
    // Not back to an open keyboard on return.
    widget.searchFocus.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttachmentsPage(controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: widget.padding,
    child: Row(
      children: [
        ?widget.leading,
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              widget.controller.location,
              widget.searchFocus,
            ]),
            builder: (context, _) {
              final location = widget.controller.location.value;
              if (location is! SearchLocation && _search.text.isNotEmpty) {
                _search.clear();
              }
              final searching =
                  location is SearchLocation || widget.searchFocus.hasFocus;
              final theme = Theme.of(context);
              return SizedBox(
                height: 44,
                child: TextField(
                  controller: _search,
                  focusNode: widget.searchFocus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: widget.controller.search,
                  decoration: InputDecoration(
                    hintText: 'Search mail',
                    prefixIcon: const Icon(AppIcons.search, size: 20),
                    // Teaches the shortcut where it is used.
                    suffixText: searching ? null : '/',
                    suffixStyle: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    // While searching: the files in your mail, and a way out.
                    suffixIcon: searching
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FilesButton(
                                onPressed: () => _openFiles(context),
                              ),
                              if (location is SearchLocation)
                                IconButton(
                                  tooltip: 'Clear search',
                                  icon: const Icon(AppIcons.close, size: 18),
                                  onPressed: () => widget.controller.search(''),
                                )
                              else
                                const SizedBox(width: 6),
                            ],
                          )
                        : null,
                    isDense: true,
                    fillColor: theme.colorScheme.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              );
            },
          ),
        ),
        if (widget.onCompose case final compose?) ...[
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'New message (C)',
            style: IconButton.styleFrom(
              backgroundColor: CitusPalette.citrus,
              foregroundColor: CitusPalette.onCitrus,
              fixedSize: const Size(44, 44),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(CitusmailTheme.radius),
              ),
            ),
            onPressed: compose,
            icon: const Icon(AppIcons.compose),
          ),
        ],
      ],
    ),
  );
}

/// "Files" in the search field: the Attachments page, for when what you
/// are looking for is a file rather than an email.
final class _FilesButton extends StatelessWidget {
  const _FilesButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Attachments from all your mail',
    child: TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      icon: const Icon(AppIcons.attachment, size: 18),
      label: const Text('Files'),
    ),
  );
}

// --------------------------------------------------------------- header

/// The view's title (with a way back, outside the inbox), and the sync
/// status line.
final class _ViewHeader extends StatelessWidget {
  const _ViewHeader({required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.location,
    builder: (context, location, _) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      child: Row(
        children: [
          Expanded(child: _title(context, location)),
          AiTidyButton(controller: controller),
          _StatusLine(controller: controller),
        ],
      ),
    ),
  );

  Widget _title(BuildContext context, MailLocation location) {
    final theme = Theme.of(context);
    final store = controller.services.store;
    final heading = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    if (location is InboxLocation) {
      return Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text('Inbox', style: heading),
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
      SnoozedLocation() => 'Snoozed',
      FollowUpsLocation() => 'Waiting for a reply',
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
          icon: const Icon(AppIcons.back),
          onPressed: () => controller.goTo(const InboxLocation()),
        ),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: heading,
          ),
        ),
        if (folder != null && controller.canHaveRules(folder))
          IconButton(
            tooltip: 'Folder rules',
            icon: const Icon(AppIcons.folderRules),
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
          AppIcons.offline,
          colors.onSurfaceVariant,
        ),
        SyncProblem(
          kind: SyncFailureKind.authentication,
          :final account,
          :final oauth,
        ) =>
          (
            oauth
                ? 'Sign-in ended ($account): sign in again'
                : 'Password not accepted ($account)',
            AppIcons.problem,
            colors.error,
          ),
        SyncProblem() => ('Can\'t update', AppIcons.problem, colors.error),
        SyncIdle(lastSynced: final at?) => (
          'Updated ${MailText.listDate(context, at)}',
          null,
          colors.onSurfaceVariant,
        ),
        SyncIdle() => ('', null, colors.onSurfaceVariant),
      };
      if (text.isEmpty) return const SizedBox.shrink();
      // A refused login is fixed, not retried.
      final fix = switch (status) {
        SyncProblem(kind: SyncFailureKind.authentication) && final problem =>
          problem,
        _ => null,
      };
      return Tooltip(
        message: fix == null
            ? 'Check for new mail'
            : (fix.oauth ? 'Sign in again' : 'Update the password'),
        child: InkWell(
          borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
          onTap: fix == null
              ? controller.syncNow
              : () => controller.reconnect(fix),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                    style: Theme.of(context).textTheme.labelMedium
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
  const _SelectionBar({
    required this.controller,
    required this.count,
    this.withTidy = false,
  });

  final MailController controller;
  final int count;

  /// "Ask AI to tidy" here too (wide screens, where this bar takes the
  /// header's place; on phones the header above keeps it).
  final bool withTidy;

  @override
  Widget build(BuildContext context) {
    final targets = controller.targets;
    final allRead = targets.every((m) => m.flags.seen);
    final allPinned = targets.every((m) => m.flags.flagged);
    final snoozed = controller.location.value is SnoozedLocation;
    final canSnooze = targets.isNotEmpty && targets.every(controller.canSnooze);
    final oneAccount = targets.map((m) => m.accountId).toSet().length == 1;
    return Container(
      color: ListColors.of(context).checked,
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel selection (Esc)',
            icon: const Icon(AppIcons.close),
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
            icon: const Icon(AppIcons.selectAll),
            onPressed: controller.selectAllVisible,
          ),
          IconButton(
            tooltip: 'Archive (E)',
            icon: const Icon(AppIcons.archive),
            onPressed: () => controller.archive(targets),
          ),
          IconButton(
            tooltip: 'Move to Trash (#)',
            icon: const Icon(AppIcons.delete),
            onPressed: () => controller.delete(targets),
          ),
          if (snoozed)
            IconButton(
              tooltip: 'Unsnooze',
              icon: const Icon(AppIcons.unsnooze),
              onPressed: () => controller.unsnooze(targets),
            ),
          if (canSnooze)
            IconButton(
              tooltip: snoozed ? 'Change snooze time (B)' : 'Snooze (B)',
              icon: const Icon(AppIcons.snooze),
              onPressed: () => SnoozeSheet.show(context, controller, targets),
            ),
          IconButton(
            tooltip: allRead ? 'Mark as unread (U)' : 'Mark as read (U)',
            icon: Icon(allRead ? AppIcons.markUnread : AppIcons.markRead),
            onPressed: () => controller.toggleRead(targets),
          ),
          IconButton(
            tooltip: allPinned ? 'Unpin (S)' : 'Pin (S)',
            icon: Icon(allPinned ? AppIcons.pinOn : AppIcons.pinOff),
            onPressed: () => controller.togglePin(targets),
          ),
          if (oneAccount)
            IconButton(
              tooltip: 'Move to folder (V)',
              icon: const Icon(AppIcons.move),
              onPressed: () => MoveDialog.show(context, controller, targets),
            ),
          if (withTidy) AiTidyButton(controller: controller),
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

  /// Mail has been checked at least once while this list was shown; till
  /// then an empty list may just be mail on its way.
  bool _checked = false;

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
    listenable: Listenable.merge([
      _c.list,
      _c.selection,
      _c.reader,
      _c.codesOffer,
      _c.status,
    ]),
    builder: (context, _) {
      final list = _c.list;
      final status = _c.status.value;
      if (status is SyncIdle && status.lastSynced != null) _checked = true;
      // The first check for mail: rows on their way, not "empty".
      const arriving = SkeletonRows(label: 'Checking for mail…');
      final firstCheck = !_checked && status is SyncRunning;
      // Asks once, in the Verification section, before tidying up codes.
      final codesOffer = _c.codesOffer.value
          ? SliverToBoxAdapter(child: CodeCleanupBanner(controller: _c))
          : null;
      if (list.location is OutboxLocation) return _outbox();
      if (list.location is FollowUpsLocation) {
        return FollowUpsView(controller: _c);
      }
      final prototype = MessageTile(
        message: MessageTile.prototype,
        controller: _c,
        open: false,
        checked: false,
        selecting: false,
      );
      if (list.showsSections) {
        if (list.sections.isEmpty &&
            list.screenerWaiting == 0 &&
            list.followUps.isEmpty &&
            list.newSinceAway.isEmpty) {
          if (firstCheck) return arriving;
          return EmptyState(
            icon: AppIcons.inbox,
            text: 'Your inbox is empty.',
            hint: 'Nothing new has arrived.',
            action: 'Check for new mail',
            onAction: _c.syncNow,
          );
        }
        return Scrollbar(
          controller: _scroll,
          child: CustomScrollView(
            controller: _scroll,
            slivers: [
              // What arrived while the user was away, at the very top.
              if (!list.newSinceAway.isEmpty)
                SliverMainAxisGroup(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: NewSinceAwayHeader(list.newSinceAway, _c),
                    ),
                    SliverPrototypeExtentList.builder(
                      prototypeItem: prototype,
                      itemCount: list.awayShown.length,
                      itemBuilder: (_, i) => _tile(list.awayShown[i]),
                    ),
                    SliverToBoxAdapter(
                      child: NewSinceAwayFooter(
                        mail: list.newSinceAway,
                        hidden:
                            list.newSinceAway.messages.length -
                            list.awayShown.length,
                        onShowAll: list.showAllAway,
                      ),
                    ),
                  ],
                ),
              // Sent mail that got no reply in time, on top.
              if (list.followUps.isNotEmpty)
                SliverToBoxAdapter(
                  child: NoReplySection(rows: list.followUps, controller: _c),
                ),
              // First-time senders, only while someone is waiting.
              if (list.screenerWaiting > 0)
                SliverToBoxAdapter(
                  child: _ScreenerEntry(
                    waiting: list.screenerWaiting,
                    onOpen: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ScreenerPage(
                          controller: _c,
                          accountId: list.location.accountId,
                        ),
                      ),
                    ),
                  ),
                ),
              for (final section in list.sections)
                SliverMainAxisGroup(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _SectionHeader(section, _c),
                    ),
                    if (section.section == SmartSection.codes) ?codesOffer,
                    if (section.expanded) ...[
                      SliverPrototypeExtentList.builder(
                        prototypeItem: prototype,
                        itemCount: section.messages.length,
                        itemBuilder: (_, i) => _tile(section.messages[i]),
                      ),
                      if (section.hasMore)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(58, 0, 16, 8),
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
        return switch (list.location) {
          SearchLocation() => const EmptyState(
            icon: AppIcons.searchOff,
            text: 'No messages found.',
            hint: 'Try other words, or the name of who wrote.',
          ),
          SnoozedLocation() => const EmptyState(
            icon: AppIcons.snooze,
            text: 'Nothing is snoozed.',
            hint:
                'Snooze an email (the clock button, or B) to have it come '
                'back to the top of your inbox when you choose.',
          ),
          PinsLocation() => const EmptyState(
            icon: AppIcons.pins,
            text: 'Nothing is pinned.',
            hint:
                'Pin an email (the pin button, or S) to keep it here, at '
                'hand.',
          ),
          _ when firstCheck => arriving,
          _ => const EmptyState(icon: AppIcons.mail, text: 'No messages here.'),
        };
      }
      return Scrollbar(
        controller: _scroll,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            if (list.location case SectionLocation(section: SmartSection.codes))
              ?codesOffer,
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
                      : list.location is SnoozedLocation
                      ? Text(
                          'Each comes back to the top of your inbox at the '
                          'time shown.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        )
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
      return const EmptyState(
        icon: AppIcons.outbox,
        text: 'Everything has been sent.',
      );
    }
    // Scheduled messages ("Send later"): a word on when they really go.
    final note = entries.any((e) => ScheduledSend.of(e) != null);
    return ListView.separated(
      itemCount: entries.length + (note ? 1 : 0),
      separatorBuilder: (_, i) =>
          note && i == 0 ? const SizedBox.shrink() : const Divider(indent: 16),
      itemBuilder: (context, i) {
        if (note && i == 0) return const _SendLaterNote();
        return _OutboxTile(entry: entries[i - (note ? 1 : 0)], controller: _c);
      },
    );
  }
}

/// An accordion header that stays at the top while its section scrolls:
/// name, unread count, the senders of a collapsed section, "mark all read".
final class _SectionHeader extends SliverPersistentHeaderDelegate {
  _SectionHeader(this.state, this.controller);

  final SectionState state;
  final MailController controller;

  static const height = 52.0;

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
    // Folded sections say who wrote (or how many), so they can stay
    // folded; an open section shows its messages, so it says nothing.
    final summary = state.expanded
        ? null
        : senders.isEmpty
        ? total
        : senders;
    return Material(
      color: ListColors.of(context).background,
      child: Semantics(
        button: true,
        expanded: state.expanded,
        label:
            '${MailText.section(section)}, ${count.total} messages, ${count.unread} unread',
        child: InkWell(
          onTap: () => controller.list.toggleSection(section),
          child: DecoratedBox(
            // A rule only while the header floats over its messages.
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: overlapsContent
                      ? colors.outlineVariant
                      : Colors.transparent,
                ),
              ),
            ),
            child: Padding(
              // The icon sits over the avatars, the name over the senders.
              padding: const EdgeInsets.fromLTRB(22, 6, 6, 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(
                      MailText.sectionIcon(section),
                      size: 18,
                      color: MailText.sectionColor(section, colors),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                MailText.section(section),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            if (count.unread > 0) ...[
                              const SizedBox(width: 10),
                              Text(
                                '${count.unread} new',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (summary != null)
                          Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (count.unread > 0)
                    IconButton(
                      tooltip: 'Mark all ${MailText.section(section)} as read',
                      icon: const Icon(AppIcons.markAllRead, size: 20),
                      color: colors.onSurfaceVariant,
                      onPressed: () => controller.markSectionRead(section),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: AnimatedRotation(
                      turns: state.expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        AppIcons.expand,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Screener at the top of the Smart Inbox: how many first-time
/// senders wait for a decision. Shaped like a section header.
final class _ScreenerEntry extends StatelessWidget {
  const _ScreenerEntry({required this.waiting, required this.onOpen});

  final int waiting;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final who = waiting == 1
        ? '1 new sender is waiting'
        : '$waiting new senders are waiting';
    return Material(
      color: ListColors.of(context).background,
      child: Semantics(
        button: true,
        label: 'Screener, $who',
        excludeSemantics: true,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 6, 8),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Icon(
                    MailText.sectionIcon(SmartSection.screener),
                    size: 18,
                    color: MailText.sectionColor(SmartSection.screener, colors),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('Screener', style: theme.textTheme.titleSmall),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$waiting',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: colors.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '$who for your OK',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(AppIcons.chevron, color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
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
    final scheduled = ScheduledSend.of(entry);
    final now = SendLaterTimes.clock();
    final waiting = scheduled != null && scheduled.waitingAt(now);
    final status = switch (entry) {
      _ when failed =>
        'Not sent: ${entry.lastError ?? 'the server refused it'}',
      _ when entry.lastError != null => 'Will try again: ${entry.lastError}',
      _ when waiting => SendLaterSheet.sendsAt(context, scheduled.at),
      _ when scheduled != null =>
        'Was due ${SendLaterSheet.describe(context, scheduled.at)}, '
            'sending now…',
      _ when entry.notBefore.isAfter(now) => 'Sending shortly…',
      _ => 'Waiting to send…',
    };
    return ListTile(
      key: ValueKey('outbox-${entry.id}'),
      leading: Icon(
        failed
            ? AppIcons.problem
            : waiting
            ? AppIcons.time
            : AppIcons.sendLater,
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
                  icon: const Icon(AppIcons.retry),
                  onPressed: () => controller.retrySend(entry),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(AppIcons.delete),
                  onPressed: () => controller.discardSend(entry),
                ),
              ],
            )
          : waiting
          ? _ScheduledMenu(scheduled: scheduled, controller: controller)
          : null,
    );
  }
}

enum _ScheduledAction { sendNow, changeTime, edit, cancel }

/// What can be done with a message waiting for its time.
final class _ScheduledMenu extends StatelessWidget {
  const _ScheduledMenu({required this.scheduled, required this.controller});

  final ScheduledSend scheduled;
  final MailController controller;

  Future<void> _act(BuildContext context, _ScheduledAction action) async {
    switch (action) {
      case _ScheduledAction.sendNow:
        controller.sendScheduledNow(scheduled);
      case _ScheduledAction.changeTime:
        final at = await SendLaterSheet.pick(context, current: scheduled.at);
        if (at == null || !context.mounted) return;
        controller.rescheduleSend(
          scheduled,
          at,
          SendLaterSheet.sendsAt(context, at),
        );
      case _ScheduledAction.edit:
        controller.editScheduled(scheduled);
      case _ScheduledAction.cancel:
        controller.cancelScheduled(scheduled);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<_ScheduledAction>(
    tooltip: 'Scheduled message options',
    icon: const Icon(AppIcons.more),
    onSelected: (action) => _act(context, action),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: _ScheduledAction.sendNow,
        child: ListTile(leading: Icon(AppIcons.send), title: Text('Send now')),
      ),
      PopupMenuItem(
        value: _ScheduledAction.changeTime,
        child: ListTile(
          leading: Icon(AppIcons.time),
          title: Text('Change time'),
        ),
      ),
      PopupMenuItem(
        value: _ScheduledAction.edit,
        child: ListTile(
          leading: Icon(AppIcons.compose),
          title: Text('Edit'),
          subtitle: Text('Back to a draft; not sent until you send it'),
        ),
      ),
      PopupMenuItem(
        value: _ScheduledAction.cancel,
        child: ListTile(
          leading: Icon(AppIcons.cancelSend),
          title: Text('Cancel sending'),
          subtitle: Text('Moves it to Drafts'),
        ),
      ),
    ],
  );
}

/// Above the Outbox list while it holds scheduled messages: what it takes
/// for them to go out, and that they stay on this device.
final class _SendLaterNote extends StatelessWidget {
  const _SendLaterNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            AppIcons.info,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              SendLaterSheet.outboxNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
