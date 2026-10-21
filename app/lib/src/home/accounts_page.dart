// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../services/app_services.dart';

/// Temporary home screen until the full inbox UI (Stage 8): accounts with
/// their sync status, and the latest messages from every inbox.
class AccountsPage extends StatefulWidget {
  const AccountsPage({
    super.key,
    required this.services,
    required this.onAddAccount,
  });

  final AppServices services;
  final VoidCallback onAddAccount;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  StreamSubscription<SyncEvent>? _events;
  final Map<int, SyncEvent> _lastEvent = {};

  MailStore get _store => widget.services.store;

  @override
  void initState() {
    super.initState();
    _events = widget.services.sync.events.listen((event) {
      if (mounted) setState(() => _lastEvent[event.accountId] = event);
    });
    widget.services.sync.start();
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(widget.services.sync.stop());
    super.dispose();
  }

  Future<void> _remove(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${account.email}?'),
        content: const Text(
          'Its mail is removed from this device and its password from the keychain. '
          'Nothing is deleted on the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.services.sync.stop();
    await widget.services.removeAccount(account);
    if (!mounted) return;
    widget.services.sync.start();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _store.accounts.all();
    final latest = _store.messages.list(
      const MessageQuery(inboxesOnly: true, limit: 50),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fmail'),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            icon: const Icon(Icons.sync),
            onPressed: () {
              for (final a in accounts) {
                unawaited(widget.services.sync.syncAccount(a.id));
              }
            },
          ),
          IconButton(
            tooltip: 'Add account',
            icon: const Icon(Icons.person_add_alt),
            onPressed: widget.onAddAccount,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final account in accounts)
            _AccountCard(
              account: account,
              store: _store,
              lastEvent: _lastEvent[account.id],
              onRemove: () => _remove(account),
            ),
          const SizedBox(height: 16),
          Text(
            'Latest in your inboxes',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (latest.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No messages yet.'),
            ),
          for (final message in latest) _MessageRow(message: message),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.store,
    required this.lastEvent,
    required this.onRemove,
  });

  final Account account;
  final MailStore store;
  final SyncEvent? lastEvent;
  final VoidCallback onRemove;

  String _status(BuildContext context) {
    final inbox = store.mailboxes.inbox(account.id);
    return switch (lastEvent) {
      AccountSyncStarted() => 'Syncing…',
      AccountSyncFailed(:final failure) => switch (failure.kind) {
        SyncFailureKind.authentication => 'Sign-in failed. Remove and add the account again with the new password.',
        SyncFailureKind.security =>
          'Connection refused for security reasons: ${failure.message}',
        SyncFailureKind.network => 'Offline or server unreachable. Retrying.',
        SyncFailureKind.server =>
          'The server had a problem: ${failure.message}',
      },
      _ when inbox?.syncState.lastSyncAt != null =>
        'Synced at ${TimeOfDay.fromDateTime(inbox!.syncState.lastSyncAt!.toLocal()).format(context)}',
      _ => 'Waiting for first sync…',
    };
  }

  @override
  Widget build(BuildContext context) {
    final inbox = store.mailboxes.inbox(account.id);
    final total = inbox == null ? 0 : store.messages.uids(inbox.id).length;
    final unread = inbox == null ? 0 : store.messages.unreadCount(inbox.id);
    final failed = lastEvent is AccountSyncFailed;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Text(account.email.characters.first.toUpperCase()),
        ),
        title: Text(account.displayName ?? account.email),
        subtitle: Text(
          '${account.displayName == null ? '' : '${account.email}\n'}Inbox: $total messages, $unread unread\n${_status(context)}',
          style: failed
              ? TextStyle(color: Theme.of(context).colorScheme.error)
              : null,
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (_) => onRemove(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'remove', child: Text('Remove account')),
          ],
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    final unread = !message.flags.seen;
    final sender =
        message.from?.displayName ?? message.from?.address ?? '(no sender)';
    final weight = unread ? FontWeight.bold : FontWeight.normal;
    return ListTile(
      dense: true,
      title: Text(
        sender,
        style: TextStyle(fontWeight: weight),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [message.subject ?? '(no subject)', ?message.snippet].join(' — '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        MaterialLocalizations.of(context)
            .formatShortDate(message.receivedAt.toLocal()),
      ),
    );
  }
}
