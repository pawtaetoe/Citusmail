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
import 'fmail_theme.dart';
import 'folder_dialogs.dart';
import 'mail_text.dart';

/// The dark navigation column: inboxes, pins, folders and accounts.
final class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.controller,
    required this.onAddAccount,
    required this.onRemoveAccount,
    this.onNavigated,
  });

  final MailController controller;
  final VoidCallback onAddAccount;
  final void Function(Account account) onRemoveAccount;

  /// Called after the user picked a place (closes the drawer on phones).
  final VoidCallback? onNavigated;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    final store = controller.services.store;
    final accounts = store.accounts.all();
    final syncing = accounts.any(
      (a) => controller.lastEvent(a.id) is AccountSyncStarted,
    );

    void go(MailLocation location) {
      controller.goTo(location);
      onNavigated?.call();
    }

    int inboxUnread(int? accountId) => controller
        .inboxCounts(accountId: accountId)
        .values
        .fold(0, (sum, c) => sum + c.unread);

    return Material(
      color: colors.background,
      child: SafeArea(
        right: false,
        child: IconTheme(
          data: IconThemeData(color: colors.muted, size: 20),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: colors.text),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                  child: Row(
                    children: [
                      Text(
                        appName,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
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
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      _Entry(
                        icon: Icons.inbox,
                        label: 'Inbox',
                        bold: true,
                        badge: inboxUnread(null),
                        selected: controller.location == const InboxLocation(),
                        onTap: () => go(const InboxLocation()),
                      ),
                      if (accounts.length > 1)
                        for (final account in accounts)
                          _Entry(
                            indent: 1,
                            label: account.displayName ?? account.email,
                            badge: inboxUnread(account.id),
                            selected:
                                controller.location ==
                                InboxLocation(accountId: account.id),
                            onTap: () =>
                                go(InboxLocation(accountId: account.id)),
                          ),
                      if (controller.outbox case final outbox
                          when outbox.isNotEmpty)
                        _Entry(
                          icon: Icons.outbox_outlined,
                          label: 'Outbox',
                          badge: outbox.length,
                          selected:
                              controller.location == const OutboxLocation(),
                          onTap: () => go(const OutboxLocation()),
                        ),
                      _Entry(
                        icon: Icons.push_pin_outlined,
                        label: 'Pins',
                        selected: controller.location == const PinsLocation(),
                        onTap: () => go(const PinsLocation()),
                      ),
                      for (final account in accounts) ...[
                        _Heading(
                          accounts.length > 1
                              ? (account.displayName ?? account.email)
                              : 'Folders',
                          onAdd: () => NewFolderDialog.show(
                            context,
                            controller,
                            account.id,
                          ),
                        ),
                        for (final (mailbox, depth) in _folders(store, account))
                          _Entry(
                            icon: MailText.folderIcon(mailbox),
                            indent: depth,
                            label: MailText.folder(mailbox),
                            badge: mailbox.specialUse == null
                                ? controller.unreadIn(mailbox.id)
                                : 0,
                            selected:
                                controller.location ==
                                FolderLocation(mailbox.id, account.id),
                            onTap: () =>
                                go(FolderLocation(mailbox.id, account.id)),
                          ),
                      ],
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                for (final account in accounts)
                  _AccountRow(
                    account: account,
                    event: controller.lastEvent(account.id),
                    onRemove: () => onRemoveAccount(account),
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
        .where((m) => !m.isInbox)
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

final class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.onAdd});

  final String text;

  /// "New folder", when given.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final muted = SidebarColors.of(context).muted;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        onAdd == null ? 18 : 6,
        8,
        onAdd == null ? 6 : 0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: muted, fontSize: 12),
            ),
          ),
          if (onAdd != null)
            IconButton(
              tooltip: 'New folder',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.create_new_folder_outlined,
                size: 18,
                color: muted,
              ),
              onPressed: onAdd,
            ),
        ],
      ),
    );
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
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12.0 + indent * 16, 9, 12, 9),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: selected ? colors.text : colors.muted),
                  const SizedBox(width: 12),
                ] else
                  Container(
                    width: 3,
                    height: 16,
                    margin: const EdgeInsets.only(right: 12),
                    color: FmailTheme.accent,
                  ),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontWeight: bold || selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (badge > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: colors.badge,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badge > 999 ? '999+' : '$badge',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An account with its sync status, and a menu to remove it.
final class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.event,
    required this.onRemove,
  });

  final Account account;
  final SyncEvent? event;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = SidebarColors.of(context);
    final (status, problem) = switch (event) {
      AccountSyncStarted() => ('Checking for mail…', false),
      AccountSyncFailed(:final failure) => (
        switch (failure.kind) {
          SyncFailureKind.authentication => 'Password not accepted',
          SyncFailureKind.security => 'Connection refused for security',
          SyncFailureKind.network => 'Offline, retrying',
          SyncFailureKind.server => 'Server problem',
        },
        true,
      ),
      AccountSynced() => ('Up to date', false),
      null => ('', false),
    };
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 20, right: 4),
      title: Text(
        account.email,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.text),
      ),
      subtitle: status.isEmpty
          ? null
          : Text(
              status,
              style: TextStyle(
                color: problem ? const Color(0xFFFF8A80) : colors.muted,
                fontSize: 12,
              ),
            ),
      trailing: PopupMenuButton<void>(
        tooltip: 'Account',
        icon: Icon(Icons.more_horiz, color: colors.muted),
        itemBuilder: (_) => [
          PopupMenuItem(onTap: onRemove, child: const Text('Remove account')),
        ],
      ),
    );
  }
}
