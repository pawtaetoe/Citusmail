// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_appsync/mail_appsync.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../security/pin_dialogs.dart';
import '../services/app_services.dart';

/// Settings > Sync between devices.
final class DeviceSyncPage extends StatefulWidget {
  const DeviceSyncPage({super.key, required this.services});

  final AppServices services;

  @override
  State<DeviceSyncPage> createState() => _DeviceSyncPageState();
}

final class _DeviceSyncPageState extends State<DeviceSyncPage> {
  bool? _enabled;

  /// Shown once after turning sync on, and on request.
  SyncCode? _shownCode;
  late final StreamSubscription<SyncEvent> _events;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // The status line follows each exchange.
    _events = widget.services.worker.events.listen((event) {
      if (event is AccountSynced && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await widget.services.deviceSync.enabled;
    if (mounted) setState(() => _enabled = enabled);
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _start() async {
    final code = await widget.services.deviceSync.start();
    if (!mounted) return;
    setState(() {
      _enabled = true;
      _shownCode = code;
    });
  }

  Future<void> _join() async {
    final joined = await showDialog<bool>(
      context: context,
      builder: (_) => _JoinDialog(services: widget.services),
    );
    if (joined != true || !mounted) return;
    setState(() => _enabled = true);
    _notice('Sync is on. Your data arrives with the next check for mail.');
  }

  Future<void> _showCode() async {
    final lock = widget.services.lock;
    // The code opens the synced data: with the app lock on, it asks first.
    if (lock.enabled &&
        !await PinDialogs.confirm(
          context,
          title: 'Show the sync code',
          check: lock.verify,
        )) {
      return;
    }
    final code = await widget.services.deviceSync.code();
    if (mounted) setState(() => _shownCode = code);
  }

  Future<void> _stop() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off sync on this device?'),
        content: const Text(
          'This device stops sharing its blocked senders, unsubscribes, '
          'folder rules and image senders. What it has now stays. Your '
          'other devices keep syncing with each other.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    final reached = await widget.services.deviceSync.stop();
    if (!mounted) return;
    setState(() {
      _enabled = false;
      _shownCode = null;
    });
    _notice(
      reached
          ? 'Sync is off on this device.'
          : 'Sync is off. This device\'s encrypted copy stays in your mail '
                'account until you turn sync on again here.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync between devices')),
      body: enabled == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: enabled ? _on(context) : _off(context),
            ),
    );
  }

  static const _what =
      'Keeps your blocked senders, unsubscribes, folder rules and image '
      'senders the same on all your devices. They travel through a folder '
      'in your own mail account, encrypted so that only your devices can '
      'read them; not even your mail provider can.';

  List<Widget> _off(BuildContext context) => [
    const Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Text(_what),
    ),
    ListTile(
      leading: const Icon(Icons.add_circle_outline),
      title: const Text('Turn on'),
      subtitle: const Text('On your first device. You get a sync code.'),
      onTap: _start,
    ),
    ListTile(
      leading: const Icon(Icons.vpn_key_outlined),
      title: const Text('I have a sync code'),
      subtitle: const Text('Join the sync your other device started.'),
      onTap: _join,
    ),
  ];

  List<Widget> _on(BuildContext context) {
    final sync = widget.services.deviceSync;
    final status = sync.status;
    final accounts = widget.services.store.accounts.all();
    final theme = Theme.of(context);
    return [
      if (_shownCode case final code?) _CodeCard(code: code),
      ListTile(
        leading: Icon(
          status?.problem == null ? Icons.sync : Icons.sync_problem,
          color: status?.problem == null ? null : theme.colorScheme.error,
        ),
        title: const Text('Sync is on'),
        subtitle: Text(_statusText(context, status)),
        trailing: TextButton(
          onPressed: () {
            sync.syncNow();
            _notice('Syncing…');
          },
          child: const Text('Sync now'),
        ),
      ),
      if (accounts.length > 1)
        ListTile(
          title: const Text('Stored in'),
          subtitle: const Text(
            'The account whose mailbox carries the data. Choose the same one '
            'on every device.',
          ),
          trailing: DropdownButton<int>(
            value: sync.account?.id,
            underline: const SizedBox.shrink(),
            items: [
              for (final a in accounts)
                DropdownMenuItem(value: a.id, child: Text(a.email)),
            ],
            onChanged: (id) {
              final chosen = accounts.where((a) => a.id == id).firstOrNull;
              setState(() => sync.account = chosen);
              sync.syncNow();
            },
          ),
        ),
      if (_shownCode == null)
        ListTile(
          leading: const Icon(Icons.vpn_key_outlined),
          title: const Text('Show the sync code'),
          subtitle: const Text('To add another device.'),
          onTap: _showCode,
        ),
      ListTile(
        leading: const Icon(Icons.sync_disabled),
        title: const Text('Turn off on this device'),
        onTap: _stop,
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(_what),
      ),
    ];
  }

  String _statusText(BuildContext context, AppDataSyncStatus? status) {
    if (status == null) return 'Waiting for the first exchange.';
    final when = TimeOfDay.fromDateTime(status.at.toLocal()).format(context);
    final day = MaterialLocalizations.of(context)
        .formatMediumDate(status.at.toLocal());
    if (status.problem case final problem?) {
      return 'Last try $day $when failed: $problem';
    }
    final others = status.devices - 1;
    final devices = switch (others) {
      0 => 'No other device yet.',
      1 => 'With 1 other device.',
      _ => 'With $others other devices.',
    };
    final damaged = status.unreadable > 0
        ? ' ${status.unreadable} stored copies couldn\'t be read.'
        : '';
    return 'Last exchange $day $when. $devices$damaged';
  }
}

/// The code, big and readable, with what to do with it.
final class _CodeCard extends StatelessWidget {
  const _CodeCard({required this.code});

  final SyncCode code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your sync code', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Semantics(
              label: 'Sync code ${code.toString().split('').join(' ')}',
              excludeSemantics: true,
              child: Text(
                code.toString(),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'On your other device, open $appName > Settings > Sync between '
              'devices > I have a sync code, and type it there. Keep it '
              'private: with it and access to your mail account, someone '
              'could read your synced data.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a code from another device.
final class _JoinDialog extends StatefulWidget {
  const _JoinDialog({required this.services});

  final AppServices services;

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

final class _JoinDialogState extends State<_JoinDialog> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = await widget.services.deviceSync.join(_code.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(
        () => _error = 'That isn\'t a sync code. Check it for typing mistakes.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Enter your sync code'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: TextField(
        controller: _code,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(fontFamily: 'monospace'),
        decoration: InputDecoration(
          labelText: 'Sync code',
          hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX',
          errorText: _error,
          errorMaxLines: 2,
        ),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Join')),
    ],
  );
}

/// Shown on the settings screen: where the user goes for sync.
final class DeviceSyncTile extends StatelessWidget {
  const DeviceSyncTile({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.devices_outlined),
    title: const Text('Sync between devices'),
    subtitle: const Text('Blocked senders, unsubscribes, rules, image senders'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceSyncPage(services: services),
      ),
    ),
  );
}
