// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'accounts_page.dart';
import 'app_icons.dart';
import 'appointments_page.dart';
import 'citusmail_theme.dart';
import 'deliveries_page.dart';
import 'discover_page.dart';
import 'feature_settings.dart';
import 'folder_dialogs.dart';
import 'mail_text.dart';
import 'privacy_report_page.dart';
import 'sender_cleanup_page.dart';
import 'settings_page.dart';
import 'subscriptions_page.dart';
import 'trips_page.dart';

/// The dark navigation column: the Smart Inbox and pins, each account's
/// inbox and folders, then pages about your mail ("Found in your mail",
/// "Tools") on a tinted band of their own. Accounts and groups fold the
/// same way, remembered. It rebuilds only when counts, the place shown or
/// sync status change.
final class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.controller,
    required this.onAddAccount,
    required this.onRemoveAccount,
    required this.onReconnectAccount,
    this.onNavigated,
    this.onCompose,
  });

  final MailController controller;
  final VoidCallback onAddAccount;
  final void Function(Account account) onRemoveAccount;

  /// A new password, or a new sign-in for an OAuth account.
  final void Function(Account account) onReconnectAccount;

  /// Called after the user picked a place (closes the drawer on phones).
  final VoidCallback? onNavigated;

  /// Shows a "New message" button at the top (wide layouts, where the
  /// sidebar is always visible).
  final VoidCallback? onCompose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller.counts,
      controller.location,
      controller.status,
    ]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final colors = SidebarColors.of(context);
    final store = controller.services.store;
    final accounts = store.accounts.all();
    final counts = controller.counts.value;
    final here = controller.location.value;
    final syncing = controller.status.value is SyncRunning;
    final several = accounts.length > 1;

    void go(MailLocation location) {
      controller.goTo(location);
      onNavigated?.call();
    }

    return Material(
      color: colors.background,
      child: SafeArea(
        right: false,
        child: IconTheme(
          data: IconThemeData(color: colors.muted, size: 20),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: colors.text),
            child: FocusTraversalGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 8, 4),
                    child: Row(
                      children: [
                        const CitusMark(size: 22),
                        const SizedBox(width: 10),
                        // Takes what the buttons leave, so any name fits.
                        Expanded(
                          child: Text(
                            appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                        ValueListenableBuilder(
                          valueListenable: controller.services.lock.isOn,
                          builder: (context, on, _) => on
                              ? IconButton(
                                  tooltip: 'Lock now',
                                  icon: Icon(
                                    AppIcons.lock,
                                    color: colors.muted,
                                  ),
                                  onPressed: controller.services.lock.lockNow,
                                )
                              : const SizedBox.shrink(),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          icon: Icon(AppIcons.settings, color: colors.muted),
                          onPressed: () {
                            onNavigated?.call();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => SettingsPage(
                                  services: controller.services,
                                  controller: controller,
                                  onShowMail: controller.search,
                                  onAddAccount: onAddAccount,
                                ),
                              ),
                            );
                          },
                        ),
                        IconButton(
                          tooltip: 'Check for new mail',
                          onPressed: syncing ? null : controller.syncNow,
                          icon: syncing
                              ? SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: colors.muted,
                                  ),
                                )
                              : Icon(AppIcons.sync, color: colors.muted),
                        ),
                      ],
                    ),
                  ),
                  if (onCompose case final compose?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: Tooltip(
                        message: 'New message (C)',
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: colors.badge,
                            foregroundColor: colors.onBadge,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          onPressed: compose,
                          icon: const Icon(AppIcons.compose, size: 20),
                          label: const Text('New message'),
                        ),
                      ),
                    ),
                  Expanded(
                    // Enter and Space work the focused row here, instead of
                    // reaching the mail shortcuts (Enter opens a message).
                    child: Shortcuts(
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter):
                            ActivateIntent(),
                        SingleActivator(LogicalKeyboardKey.numpadEnter):
                            ActivateIntent(),
                        SingleActivator(LogicalKeyboardKey.space):
                            ActivateIntent(),
                      },
                      child: ListView(
                        padding: const EdgeInsets.only(top: 2, bottom: 8),
                        children: [
                          _Entry(
                            icon: AppIcons.inbox,
                            label: 'Inbox',
                            bold: true,
                            badge: counts.inboxUnread,
                            selected: here == const InboxLocation(),
                            onTap: () => go(const InboxLocation()),
                          ),
                          _Entry(
                            icon: AppIcons.pins,
                            label: 'Pins',
                            selected: here == const PinsLocation(),
                            onTap: () => go(const PinsLocation()),
                          ),
                          if (counts.outbox > 0)
                            _Entry(
                              icon: AppIcons.outbox,
                              label: 'Outbox',
                              badge: counts.outbox,
                              selected: here == const OutboxLocation(),
                              onTap: () => go(const OutboxLocation()),
                            ),
                          // While something is snoozed.
                          if (counts.snoozed > 0)
                            _Entry(
                              icon: AppIcons.snoozed,
                              label: 'Snoozed',
                              selected: here == const SnoozedLocation(),
                              onTap: () => go(const SnoozedLocation()),
                            ),
                          // While a sent email waits for a reply.
                          if (counts.followUps > 0)
                            _Entry(
                              icon: AppIcons.waiting,
                              label: 'Waiting for a reply',
                              selected: here == const FollowUpsLocation(),
                              onTap: () => go(const FollowUpsLocation()),
                            ),
                          if (several)
                            const _SectionHeading('Accounts')
                          else
                            const SizedBox(height: 8),
                          // One block per account: its inbox and folders.
                          // With several accounts each one folds away
                          // (remembered), showing its unread count.
                          for (final account in accounts)
                            _AccountBlock(
                              key: ValueKey('account-${account.id}'),
                              account: account,
                              memory: several
                                  ? _OpenSet(store, _OpenSet.accountsKey)
                                  : null,
                              unread: counts.perAccountUnread[account.id] ?? 0,
                              event: controller.lastEvent(account.id),
                              onNewFolder: () => NewFolderDialog.show(
                                context,
                                controller,
                                account.id,
                              ),
                              onRemove: () => onRemoveAccount(account),
                              onReconnect: () => onReconnectAccount(account),
                              folders: [
                                // With one account, the Inbox above is its
                                // inbox.
                                if (several)
                                  _Entry(
                                    icon: AppIcons.inbox,
                                    indent: 1,
                                    label: 'Inbox',
                                    badge:
                                        counts.perAccountUnread[account.id] ??
                                        0,
                                    selected:
                                        here ==
                                        InboxLocation(accountId: account.id),
                                    onTap: () => go(
                                      InboxLocation(accountId: account.id),
                                    ),
                                  ),
                                for (final (mailbox, depth) in _folders(
                                  store,
                                  account,
                                ))
                                  _Entry(
                                    icon: MailText.folderIcon(mailbox),
                                    indent: depth + (several ? 1 : 0),
                                    label: MailText.folder(mailbox),
                                    badge: mailbox.specialUse == null
                                        ? counts.folderUnread[mailbox.id] ?? 0
                                        : 0,
                                    selected:
                                        here ==
                                        FolderLocation(mailbox.id, account.id),
                                    onTap: () => go(
                                      FolderLocation(mailbox.id, account.id),
                                    ),
                                  ),
                              ],
                            ),
                          // Pages about your mail, apart from the places to
                          // read it.
                          _FeaturePanel(
                            memory: _OpenSet(store, _OpenSet.groupsKey),
                            groups: _featureGroups(),
                            onOpen: (page) {
                              onNavigated?.call();
                              Navigator.of(context)
                                  .push(MaterialPageRoute<void>(builder: page));
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(color: colors.selected, height: 1),
                  const SizedBox(height: 2),
                  // One line for all accounts (a single problem shows
                  // only on its account's block).
                  _SyncSummary(
                    accounts: accounts,
                    eventOf: controller.lastEvent,
                    onTap: () {
                      onNavigated?.call();
                      CheckingMailSheet.show(context, controller);
                    },
                  ),
                  // Always in view, not inside a folded group, so
                  // everything the app does is one tap away.
                  _Entry(
                    icon: AppIcons.allFeatures,
                    label: 'All features',
                    onTap: () {
                      onNavigated?.call();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DiscoverPage(controller: controller),
                        ),
                      );
                    },
                  ),
                  _Entry(
                    icon: AppIcons.addAccount,
                    label: 'Add account',
                    onTap: onAddAccount,
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The pages below the accounts, in folding groups. Adding a page is
  /// one line here.
  List<_FeatureGroup> _featureGroups() => [
    (
      id: 'found',
      title: 'Found in your mail',
      pages: [
        (
          icon: AppIcons.subscriptions,
          label: 'Subscriptions',
          page: (_) => SubscriptionsPage(controller: controller),
        ),
        (
          icon: AppIcons.deliveries,
          label: 'Deliveries',
          page: (_) => DeliveriesPage(controller: controller),
        ),
        (
          icon: AppIcons.trips,
          label: 'Trips',
          page: (_) => TripsPage(controller: controller),
        ),
        (
          icon: AppIcons.appointments,
          label: 'Appointments',
          page: (_) => AppointmentsPage(controller: controller),
        ),
        (
          icon: AppIcons.onlineAccounts,
          label: 'Online accounts',
          page: (_) => AccountsPage(controller: controller),
        ),
      ],
    ),
    (
      id: 'tools',
      title: 'Tools',
      pages: [
        (
          icon: AppIcons.cleanUp,
          label: 'Clean up',
          page: (_) => SenderCleanupPage(controller: controller),
        ),
        (
          icon: AppIcons.privacyReport,
          label: 'Privacy report',
          page: (_) => PrivacyReportPage(
            services: controller.services,
            onShowMail: controller.search,
          ),
        ),
      ],
    ),
  ];

  /// The account's folders other than the inbox: standard folders first,
  /// then the rest as a tree (depth from the folder separator).
  static List<(StoredMailbox, int)> _folders(MailStore store, Account account) {
    const order = [
      SpecialUse.sent,
      SpecialUse.drafts,
      SpecialUse.archive,
      SpecialUse.junk,
      SpecialUse.trash,
    ];
    final all = store.mailboxes
        .forAccount(account.id)
        .where((m) => !m.isInbox && !m.isAppData)
        .toList();
    final special = [
      for (final use in order)
        ...all.where((m) => m.specialUse == use && m.selectable),
    ];
    final others = all.where((m) => !special.contains(m)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    int depth(StoredMailbox m) {
      final delimiter = m.delimiter;
      if (delimiter == null || delimiter.isEmpty) return 0;
      final parts = m.name.split(delimiter);
      // cPanel-style servers put every folder under "INBOX.".
      final relative = parts.length > 1 && parts.first.toUpperCase() == 'INBOX'
          ? parts.length - 2
          : parts.length - 1;
      return relative.clamp(0, 4);
    }

    return [
      for (final m in special) (m, 0),
      for (final m in others)
        if (m.selectable ||
            others.any((o) => o != m && o.name.startsWith(m.name)))
          (m, depth(m)),
    ];
  }
}

/// One size for every row, icon and step of indentation in the sidebar,
/// so it reads as one list.
abstract final class _Size {
  /// Height of an entry or a folding header (and so its tap target).
  static const row = 40.0;
  static const icon = 20.0;
  static const iconGap = 12.0;

  /// One level of nesting (a folder in a folder, an entry in a group).
  static const indent = 16.0;

  /// From the row's edge to its icon or chevron.
  static const start = 12.0;

  /// From the row's edge to its count.
  static const end = 10.0;

  /// How long folding takes: enough to see where things went.
  static const fold = Duration(milliseconds: 160);
}

/// A small, muted label over a group of entries.
final class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  /// Small, muted, a little spaced: also the style of the folding group
  /// headings below the accounts.
  static TextStyle style(SidebarColors colors) => TextStyle(
    color: colors.muted,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 12, 2),
    child: Semantics(
      header: true,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style(SidebarColors.of(context)),
      ),
    ),
  );
}

/// An unread count, right-aligned in its row. Large ones read "999+".
final class _Count extends StatelessWidget {
  const _Count(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.badge,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 999 ? '999+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: colors.onBadge,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A place to go: an icon, a label and an unread count.
final class _Entry extends StatelessWidget {
  const _Entry({
    required this.icon,
    required this.label,
    required this.onTap,
    this.indent = 0,
    this.badge = 0,
    this.selected = false,
    this.bold = false,
    this.detail,
    this.detailColor,
    this.dot,
  });

  final IconData icon;
  final String label;

  /// A short second line under [label] (a status), in [detailColor].
  final String? detail;
  final Color? detailColor;

  /// A status dot at the end of the row.
  final Color? dot;
  final int indent;
  final int badge;
  final bool selected;
  final bool bold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? colors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            hoverColor: colors.hover,
            focusColor: colors.selected,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _Size.row),
              child: Stack(
                alignment: AlignmentDirectional.centerStart,
                children: [
                  // Where you are, without relying on colour alone.
                  if (selected)
                    Positioned(
                      left: 0,
                      top: 9,
                      bottom: 9,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: colors.indicator,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      _Size.start + indent * _Size.indent,
                      6,
                      _Size.end,
                      6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          icon,
                          size: _Size.icon,
                          color: selected ? colors.text : colors.muted,
                        ),
                        const SizedBox(width: _Size.iconGap),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.text,
                                  fontSize: 14,
                                  fontWeight: bold || selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                              if (detail != null)
                                Text(
                                  detail!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: detailColor ?? colors.muted,
                                    fontSize: 12.5,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (dot != null)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsetsDirectional.only(start: 8),
                            decoration: BoxDecoration(
                              color: dot,
                              shape: BoxShape.circle,
                            ),
                          ),
                        if (badge > 0) _Count(badge),
                      ],
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

/// Which folding parts of the sidebar are open, remembered in the
/// settings store as a list of ids. Everything starts folded.
final class _OpenSet {
  const _OpenSet(this.store, this.key);

  /// Account ids.
  static const accountsKey = 'ui.openAccounts';

  /// Feature group ids ("found", "tools").
  static const groupsKey = 'ui.openSidebarGroups';

  final MailStore store;
  final String key;

  Set<String> _read() => {
    ...?store.settings.read(key)?.split(',').where((s) => s.isNotEmpty),
  };

  bool contains(String id) => _read().contains(id);

  void set(String id, {required bool open}) {
    final ids = _read();
    open ? ids.add(id) : ids.remove(id);
    store.settings.write(key, ids.join(','));
  }
}

/// A header and the entries under it, folding away the same way
/// everywhere: the chevron turns, the entries slide in or out, and the
/// choice is remembered in [memory] (null: it doesn't fold). Folded, the
/// entry being shown stays in sight, so it's clear where the list comes
/// from.
final class _Fold extends StatefulWidget {
  const _Fold({
    super.key,
    required this.memory,
    required this.id,
    required this.header,
    required this.children,
  });

  final _OpenSet? memory;
  final String id;

  /// The header, given whether it's open and how to fold it (null when it
  /// doesn't fold).
  final Widget Function(bool open, VoidCallback? toggle) header;
  final List<Widget> children;

  @override
  State<_Fold> createState() => _FoldState();
}

final class _FoldState extends State<_Fold> {
  late bool _open = widget.memory?.contains(widget.id) ?? true;

  /// Scrolls what was just opened into view once it has slid open.
  bool _reveal = false;

  void _toggle() {
    setState(() => _open = !_open);
    _reveal = _open;
    widget.memory?.set(widget.id, open: _open);
  }

  void _revealOpened() {
    if (!_reveal) return;
    _reveal = false;
    // After this frame's layout, when the new size is known.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scrollable = Scrollable.maybeOf(context);
      final height = context.size?.height;
      if (scrollable == null || height == null) return;
      // All of it if it fits; otherwise its header at the top.
      final fits = height <= scrollable.position.viewportDimension;
      Scrollable.ensureVisible(
        context,
        duration: _Size.fold,
        alignmentPolicy: fits
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final foldable = widget.memory != null;
    final open = !foldable || _open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header(open, foldable ? _toggle : null),
        AnimatedSize(
          duration: _Size.fold,
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          onEnd: _revealOpened,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: open
                ? widget.children
                : [
                    for (final child in widget.children)
                      if (child is _Entry && child.selected) child,
                  ],
          ),
        ),
      ],
    );
  }
}

/// The header of a [_Fold]: a turning chevron, then [leading] (an
/// account's status dot), the title (cut short, with a tooltip, when
/// long), a problem on a second line, and a count. Screen readers hear
/// "Show …" or "Hide …"; Enter or Space folds it.
final class _FoldHeader extends StatelessWidget {
  const _FoldHeader({
    required this.title,
    required this.what,
    required this.open,
    required this.onToggle,
    this.tooltip,
    this.leading,
    this.problem,
    this.badge = 0,
    this.trailing,
    this.heading = false,
  });

  final String title;

  /// What folds, for screen readers: "Show $what".
  final String what;

  /// A group heading (small, muted, like [_SectionHeading]) rather than
  /// an account's name.
  final bool heading;
  final bool open;

  /// Null when it doesn't fold: then it is a plain heading.
  final VoidCallback? onToggle;
  final String? tooltip;
  final Widget? leading;
  final String? problem;
  final int badge;

  /// Beside the header, outside the folding part (an account's menu).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    final foldable = onToggle != null;
    final problem = this.problem;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _Size.row),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _Size.start,
          4,
          trailing == null ? _Size.end : 0,
          4,
        ),
        child: Row(
          children: [
            if (foldable) ...[
              AnimatedRotation(
                turns: open ? 0 : -0.25,
                duration: _Size.fold,
                child: Icon(
                  AppIcons.expand,
                  size: _Size.icon,
                  color: colors.muted,
                ),
              ),
              const SizedBox(width: _Size.iconGap - 4),
            ],
            if (leading case final leading?) ...[
              leading,
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: tooltip ?? title,
                    excludeFromSemantics: true,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: heading
                          ? _SectionHeading.style(colors)
                          : TextStyle(
                              color: colors.text,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                    ),
                  ),
                  if (problem != null)
                    Text(
                      problem,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.problem, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (badge > 0) _Count(badge),
          ],
        ),
      ),
    );
    final value = [if (badge > 0) '$badge unread', ?problem].join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: foldable,
              header: !foldable,
              expanded: foldable ? open : null,
              label: foldable ? '${open ? 'Hide' : 'Show'} $what' : title,
              value: value.isEmpty ? null : value,
              excludeSemantics: true,
              onTap: onToggle,
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
                clipBehavior: Clip.antiAlias,
                child: foldable
                    ? InkWell(
                        hoverColor: colors.hover,
                        focusColor: colors.selected,
                        onTap: onToggle,
                        child: row,
                      )
                    : row,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A page the sidebar opens (Subscriptions, Clean up…).
typedef _Feature = ({IconData icon, String label, WidgetBuilder page});

/// A folding group of pages, such as "Tools".
typedef _FeatureGroup = ({String id, String title, List<_Feature> pages});

/// Pages about your mail, apart from the places to read it: below the
/// accounts, under small muted headings, so they read as features, not
/// folders. Each group folds (folded at first; remembered).
final class _FeaturePanel extends StatelessWidget {
  const _FeaturePanel({
    required this.memory,
    required this.groups,
    required this.onOpen,
  });

  final _OpenSet memory;
  final List<_FeatureGroup> groups;
  final void Function(WidgetBuilder page) onOpen;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: CitusSpace.l),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups)
          _Fold(
            key: ValueKey('group-${group.id}'),
            memory: memory,
            id: group.id,
            header: (open, toggle) => _FoldHeader(
              title: group.title,
              what: group.title,
              open: open,
              onToggle: toggle,
              heading: true,
            ),
            children: [
              for (final page in group.pages)
                _Entry(
                  icon: page.icon,
                  label: page.label,
                  indent: 1,
                  onTap: () => onOpen(page.page),
                ),
            ],
          ),
      ],
    ),
  );
}

/// What an account's last sync says, in a few words, and whether it is a
/// problem.
(String, bool) _statusOf(Account account, SyncEvent? event) => switch (event) {
  AccountSyncStarted() => ('Checking for mail…', false),
  AccountSyncFailed(:final failure) => (
    switch (failure.kind) {
      SyncFailureKind.authentication =>
        account.usesOAuth ? 'Sign-in ended' : 'Password not accepted',
      SyncFailureKind.security => 'Connection refused for security',
      SyncFailureKind.network => 'Offline, retrying',
      SyncFailureKind.server => 'Server problem',
    },
    true,
  ),
  AccountSynced() => ('Up to date', false),
  null => ('', false),
};

Color _dotOf(SidebarColors colors, SyncEvent? event) => switch (event) {
  AccountSyncFailed() => colors.problem,
  AccountSyncStarted() => colors.badge,
  AccountSynced() => const Color(0xFF6FD6A8),
  null => colors.muted,
};

/// An account's inbox and folders under a header with its address, status
/// dot and menu (new folder, sign in again, remove). With several
/// accounts the block folds away (remembered), its header showing the
/// account's unread count; a sync problem shows there too.
final class _AccountBlock extends StatelessWidget {
  const _AccountBlock({
    super.key,
    required this.account,
    required this.memory,
    required this.unread,
    required this.event,
    required this.folders,
    required this.onNewFolder,
    required this.onRemove,
    required this.onReconnect,
  });

  final Account account;

  /// Where its folding is remembered; null when it doesn't fold (one
  /// account).
  final _OpenSet? memory;
  final int unread;
  final SyncEvent? event;
  final List<Widget> folders;
  final VoidCallback onNewFolder;
  final VoidCallback onRemove;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    final (status, problem) = _statusOf(account, event);
    final name = account.displayName ?? account.email;
    return _Fold(
      memory: memory,
      id: '${account.id}',
      header: (open, toggle) => _FoldHeader(
        title: name,
        what: 'folders of $name',
        tooltip: name == account.email ? name : '$name <${account.email}>',
        open: open,
        onToggle: toggle,
        // While folded; open, its Inbox shows it.
        badge: toggle != null && !open ? unread : 0,
        problem: problem ? status : null,
        leading: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: _dotOf(colors, event),
            shape: BoxShape.circle,
          ),
        ),
        trailing: PopupMenuButton<void>(
          tooltip: 'Account',
          icon: Icon(
            AppIcons.moreHorizontal,
            size: _Size.icon,
            color: colors.muted,
          ),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(_Size.row),
            minimumSize: const Size.square(_Size.row),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          itemBuilder: (_) => [
            PopupMenuItem(onTap: onNewFolder, child: const Text('New folder')),
            PopupMenuItem(
              onTap: onReconnect,
              child: Text(
                account.usesOAuth ? 'Sign in again' : 'Update password',
              ),
            ),
            PopupMenuItem(onTap: onRemove, child: const Text('Remove account')),
          ],
        ),
      ),
      children: folders,
    );
  }
}

/// The accounts' sync status in one line: "All accounts up to date", or
/// how many accounts need looking at. A single account's problem is not
/// repeated here: its block shows it.
final class _SyncSummary extends StatelessWidget {
  const _SyncSummary({
    required this.accounts,
    required this.eventOf,
    required this.onTap,
  });

  final List<Account> accounts;
  final SyncEvent? Function(int accountId) eventOf;

  /// Notifications and how mail is checked.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    if (accounts.isEmpty) return const SizedBox.shrink();
    final failed = [
      for (final a in accounts)
        if (eventOf(a.id) is AccountSyncFailed) a,
    ];
    final checking = accounts.any((a) => eventOf(a.id) is AccountSyncStarted);
    // A row like the ones around it ("Notification settings", not the
    // Inbox's Notifications section); a status
    // only when it says something (one failed account says so on its
    // own block, right under its address).
    String? status;
    Color? dot;
    if (failed.length > 1) {
      status = '${failed.length} accounts need attention';
      dot = colors.problem;
    } else if (failed.isEmpty && checking) {
      status = 'Checking for mail…';
      dot = colors.badge;
    } else if (failed.isEmpty &&
        accounts.every((a) => eventOf(a.id) is AccountSynced)) {
      status = accounts.length == 1 ? 'Up to date' : 'All accounts up to date';
      dot = const Color(0xFF6FD6A8);
    }
    // A tap: notifications and how mail is checked (Instant mail).
    return Tooltip(
      message: 'Notifications and checking mail',
      child: _Entry(
        icon: AppIcons.notifications,
        label: 'Notification settings',
        detail: status,
        detailColor: failed.length > 1 ? colors.problem : null,
        dot: dot,
        onTap: onTap,
      ),
    );
  }
}
