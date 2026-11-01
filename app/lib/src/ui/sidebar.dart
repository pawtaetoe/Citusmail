// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'citusmail_theme.dart';
import 'folder_dialogs.dart';
import 'mail_text.dart';
import 'settings_page.dart';
import 'subscriptions_page.dart';

/// The dark navigation column: inboxes, pins, folders and accounts. It
/// rebuilds only when counts, the place shown or sync status change.
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
                    padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
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
                                    Icons.lock_outline,
                                    color: colors.muted,
                                  ),
                                  onPressed: controller.services.lock.lockNow,
                                )
                              : const SizedBox.shrink(),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          icon: Icon(
                            Icons.settings_outlined,
                            color: colors.muted,
                          ),
                          onPressed: () {
                            onNavigated?.call();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    SettingsPage(services: controller.services),
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
                              : Icon(Icons.sync, color: colors.muted),
                        ),
                      ],
                    ),
                  ),
                  if (onCompose case final compose?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
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
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          label: const Text('New message'),
                        ),
                      ),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        _Entry(
                          icon: Icons.inbox,
                          label: 'Inbox',
                          bold: true,
                          badge: counts.inboxUnread,
                          selected: here == const InboxLocation(),
                          onTap: () => go(const InboxLocation()),
                        ),
                        if (accounts.length > 1)
                          for (final account in accounts)
                            _Entry(
                              indent: 1,
                              label: account.displayName ?? account.email,
                              badge: counts.perAccountUnread[account.id] ?? 0,
                              selected:
                                  here == InboxLocation(accountId: account.id),
                              onTap: () =>
                                  go(InboxLocation(accountId: account.id)),
                            ),
                        if (counts.outbox > 0)
                          _Entry(
                            icon: Icons.outbox_outlined,
                            label: 'Outbox',
                            badge: counts.outbox,
                            selected: here == const OutboxLocation(),
                            onTap: () => go(const OutboxLocation()),
                          ),
                        _Entry(
                          icon: Icons.push_pin_outlined,
                          label: 'Pins',
                          selected: here == const PinsLocation(),
                          onTap: () => go(const PinsLocation()),
                        ),
                        _Entry(
                          icon: Icons.autorenew,
                          label: 'Subscriptions',
                          selected: false,
                          onTap: () {
                            onNavigated?.call();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    SubscriptionsPage(controller: controller),
                              ),
                            );
                          },
                        ),
                        // One block per account: its status, menu and
                        // folders. With several accounts each one folds
                        // away (remembered), so the list stays short.
                        for (final account in accounts)
                          _AccountBlock(
                            key: ValueKey('account-${account.id}'),
                            account: account,
                            store: store,
                            collapsible: accounts.length > 1,
                            holdsSelection:
                                here is FolderLocation &&
                                here.accountId == account.id,
                            event: controller.lastEvent(account.id),
                            onNewFolder: () => NewFolderDialog.show(
                              context,
                              controller,
                              account.id,
                            ),
                            onRemove: () => onRemoveAccount(account),
                            onReconnect: () => onReconnectAccount(account),
                            folders: [
                              for (final (mailbox, depth) in _folders(
                                store,
                                account,
                              ))
                                _Entry(
                                  icon: MailText.folderIcon(mailbox),
                                  indent: depth,
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
                      ],
                    ),
                  ),
                  Divider(color: colors.selected, height: 1),
                  const SizedBox(height: 6),
                  // One line for all accounts; a problem names the
                  // account (its block shows it too).
                  _SyncSummary(
                    accounts: accounts,
                    eventOf: controller.lastEvent,
                  ),
                  _Entry(
                    icon: Icons.person_add_alt,
                    label: 'Add account',
                    onTap: onAddAccount,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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

final class _Entry extends StatelessWidget {
  const _Entry({
    required this.label,
    required this.onTap,
    this.icon,
    this.indent = 0,
    this.badge = 0,
    this.selected = false,
    this.bold = false,
  });

  final IconData? icon;
  final String label;
  final int indent;
  final int badge;
  final bool selected;
  final bool bold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? colors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          hoverColor: colors.hover,
          onTap: onTap,
          child: Stack(
            children: [
              // Where you are, without relying on colour alone.
              if (selected)
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: colors.indicator,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(12.0 + indent * 16, 9, 10, 9),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: selected ? colors.text : colors.muted),
                      const SizedBox(width: 12),
                    ] else
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(left: 2, right: 12),
                        decoration: BoxDecoration(
                          color: colors.muted,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Expanded(
                      child: Text(
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
                    ),
                    if (badge > 0)
                      Container(
                        constraints: const BoxConstraints(minWidth: 22),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.badge,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          badge > 999 ? '999+' : '$badge',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.onBadge,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

/// An account's folders under a header with its address, status dot and
/// menu (sign in again, remove). With several accounts the folders fold
/// away; the choice is remembered, and the block opens by itself when one
/// of its folders is shown. A sync problem shows on the header even when
/// folded.
final class _AccountBlock extends StatefulWidget {
  const _AccountBlock({
    super.key,
    required this.account,
    required this.store,
    required this.collapsible,
    required this.holdsSelection,
    required this.event,
    required this.folders,
    required this.onNewFolder,
    required this.onRemove,
    required this.onReconnect,
  });

  final Account account;
  final MailStore store;
  final bool collapsible;

  /// One of its folders is being shown.
  final bool holdsSelection;
  final SyncEvent? event;
  final List<Widget> folders;
  final VoidCallback onNewFolder;
  final VoidCallback onRemove;
  final VoidCallback onReconnect;

  static const _openKey = 'ui.openAccounts';

  @override
  State<_AccountBlock> createState() => _AccountBlockState();
}

final class _AccountBlockState extends State<_AccountBlock> {
  late bool _open = _stored().contains('${widget.account.id}');

  Set<String> _stored() => {
    ...?widget.store.settings
        .read(_AccountBlock._openKey)
        ?.split(',')
        .where((s) => s.isNotEmpty),
  };

  void _toggle() {
    setState(() => _open = !_open);
    final ids = _stored();
    final id = '${widget.account.id}';
    _open ? ids.add(id) : ids.remove(id);
    widget.store.settings.write(_AccountBlock._openKey, ids.join(','));
  }

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    final account = widget.account;
    final open = !widget.collapsible || _open || widget.holdsSelection;
    final (status, problem) = _statusOf(account, widget.event);
    final name = account.displayName ?? account.email;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 4, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          hoverColor: colors.hover,
          onTap: widget.collapsible ? _toggle : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _dotOf(colors, widget.event),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // Problems always show; "Up to date" only when there
                      // is one account (the summary below covers several).
                      if (problem || (!widget.collapsible && status.isNotEmpty))
                        Text(
                          status,
                          style: TextStyle(
                            color: problem ? colors.problem : colors.muted,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<void>(
                  tooltip: 'Account',
                  icon: Icon(Icons.more_horiz, size: 20, color: colors.muted),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      onTap: widget.onNewFolder,
                      child: const Text('New folder'),
                    ),
                    PopupMenuItem(
                      onTap: widget.onReconnect,
                      child: Text(
                        account.usesOAuth ? 'Sign in again' : 'Update password',
                      ),
                    ),
                    PopupMenuItem(
                      onTap: widget.onRemove,
                      child: const Text('Remove account'),
                    ),
                  ],
                ),
                if (widget.collapsible)
                  Semantics(
                    label: open ? 'Hide folders' : 'Show folders',
                    child: Icon(
                      open ? Icons.expand_less : Icons.expand_more,
                      color: colors.muted,
                    ),
                  ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.topCenter,
          child: open
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: widget.folders,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// The accounts' sync status in one line: "All accounts up to date", or
/// the problem to look at.
final class _SyncSummary extends StatelessWidget {
  const _SyncSummary({required this.accounts, required this.eventOf});

  final List<Account> accounts;
  final SyncEvent? Function(int accountId) eventOf;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    if (accounts.isEmpty) return const SizedBox.shrink();
    final failed = [
      for (final a in accounts)
        if (eventOf(a.id) is AccountSyncFailed) a,
    ];
    final checking = accounts.any((a) => eventOf(a.id) is AccountSyncStarted);
    final String text;
    final Color dot;
    if (failed.length == 1) {
      text =
          '${failed.single.email}: ${_statusOf(failed.single, eventOf(failed.single.id)).$1}';
      dot = colors.problem;
    } else if (failed.length > 1) {
      text = '${failed.length} accounts need attention';
      dot = colors.problem;
    } else if (checking) {
      text = 'Checking for mail…';
      dot = colors.badge;
    } else if (accounts.every((a) => eventOf(a.id) is AccountSynced)) {
      text = accounts.length == 1 ? 'Up to date' : 'All accounts up to date';
      dot = const Color(0xFF6FD6A8);
    } else {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: failed.isEmpty ? colors.muted : colors.problem,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
