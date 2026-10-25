// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../background/background_mail.dart';
import '../security/app_lock.dart';
import '../security/pin_dialogs.dart';
import '../services/app_services.dart';
import '../services/link_safety.dart';
import '../services/virus_total_checks.dart';
import 'block_dialog.dart';
import 'device_sync_page.dart';
import 'image_senders_page.dart';

/// One account's server rules, in words.
String serverRulesText(ServerRulesStatus? status) => switch (status?.state) {
  null => 'Set up with the next check for mail.',
  ServerRulesState.active => 'Running on the server.',
  ServerRulesState.nothingToRun =>
    'Nothing to run yet: no blocked senders or folder rules.',
  ServerRulesState.otherScriptActive =>
    'The server already runs another filter ("${status!.detail}"), so the rules '
        'run in $appName only.',
  ServerRulesState.notSupported =>
    'This server doesn\'t support rules on the server.',
  ServerRulesState.failed =>
    'Couldn\'t update the server: ${status!.detail ?? 'unknown problem'}. '
        'Tried again later.',
};

/// App settings: notifications, instant mail on Android, and what the app
/// does with your data.
final class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.services, this.isAndroid});

  final AppServices services;

  /// Overrides the platform (tests).
  final bool? isAndroid;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  bool get _android => widget.isAndroid ?? Platform.isAndroid;

  AppLock get _lock => widget.services.lock;
  bool _biometricsAvailable = false;

  @override
  void initState() {
    super.initState();
    _lock.biometrics.isAvailable().then((available) {
      if (mounted) setState(() => _biometricsAvailable = available);
    });
  }

  Future<void> _setLock(bool on) async {
    if (on) {
      final pin = await PinDialogs.choose(context);
      if (pin == null) return;
      await _lock.setPin(pin);
    } else {
      if (!await PinDialogs.confirm(
        context,
        title: 'Turn off the app lock?',
        check: _lock.disable,
      )) {
        return;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _changePin() async {
    if (!await PinDialogs.confirm(
      context,
      title: 'Change PIN',
      check: _lock.verify,
    )) {
      return;
    }
    if (!mounted) return;
    final pin = await PinDialogs.choose(context, title: 'Choose a new PIN');
    if (pin == null) return;
    await _lock.setPin(pin);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('PIN changed')));
  }

  Future<void> _setBiometrics(bool on) async {
    // Turning it on asks once, so it is known to work for this person.
    if (on &&
        !await _lock.biometrics.authenticate(
          'Confirm to unlock $appName this way',
        )) {
      return;
    }
    setState(() => _lock.useBiometrics = on);
  }

  List<Widget> _lockSettings() {
    final enabled = _lock.enabled;
    return [
      SwitchListTile(
        title: const Text('App lock'),
        subtitle: Text(
          'Ask for a PIN to open $appName. While locked, notifications '
          'show only that there is new mail.',
        ),
        value: enabled,
        onChanged: _setLock,
      ),
      if (enabled) ...[
        ListTile(
          title: const Text('Lock'),
          subtitle: const Text('After leaving the app'),
          trailing: DropdownButton<LockTimeout>(
            value: _lock.timeout,
            underline: const SizedBox.shrink(),
            items: [
              for (final t in LockTimeout.values)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (t) {
              if (t != null) setState(() => _lock.timeout = t);
            },
          ),
        ),
        if (_biometricsAvailable)
          SwitchListTile(
            title: Text('Unlock with ${_lock.biometrics.name}'),
            value: _lock.useBiometrics,
            onChanged: _setBiometrics,
          ),
        ListTile(title: const Text('Change PIN'), onTap: _changePin),
      ],
    ];
  }

  Future<void> _setInstant(bool on) async {
    setState(() => widget.services.settings.instantMail = on);
    try {
      await BackgroundMail.setInstant(on);
    } on Object {
      if (!mounted) return;
      setState(() => widget.services.settings.instantMail = !on);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Android didn\'t allow instant mail right now.'),
        ),
      );
    }
  }

  Future<void> _setSafeBrowsing(bool on) async {
    final safety = widget.services.linkSafety;
    if (!on) {
      await safety.disable();
    } else {
      await showDialog<void>(
        context: context,
        builder: (_) => SafeBrowsingDialog(safety: safety),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _setVirusTotal(bool on) async {
    if (!on) {
      await widget.services.virusTotal.disable();
    } else {
      await showDialog<void>(
        context: context,
        builder: (_) => VirusTotalDialog(checks: widget.services.virusTotal),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _setServerRules(bool on) async {
    setState(() => widget.services.settings.serverRules = on);
    try {
      await widget.services.worker.syncNow();
    } on SyncWorkerException {
      // Tried again with the next sync.
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.services.settings;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _Group('Notifications'),
          SwitchListTile(
            title: const Text('New mail notifications'),
            subtitle: const Text(
              'Sender and subject of new mail in Important and General. '
              'The lock screen shows only that there is new mail.',
            ),
            value: settings.notifications,
            onChanged: (on) => setState(() => settings.notifications = on),
          ),
          if (_android) ...[
            SwitchListTile(
              title: const Text('Instant mail'),
              subtitle: const Text(
                'Keeps a live connection to your mail server so new mail arrives at once. '
                'Android requires a permanent "$appName is connected" notification and it uses more '
                'battery. When off, $appName checks about every 15 minutes.',
              ),
              value: settings.instantMail,
              onChanged: _setInstant,
            ),
          ],
          const _Group('Security'),
          ..._lockSettings(),
          SwitchListTile(
            secondary: const Icon(Icons.travel_explore),
            title: const Text('Check links with Google Safe Browsing'),
            subtitle: Text(
              widget.services.linkSafety.enabled
                  ? (widget.services.linkSafety.status ??
                        'Downloading Google\'s lists…')
                  : 'Off. Links are checked on this device only.',
            ),
            value: widget.services.linkSafety.enabled,
            onChanged: _setSafeBrowsing,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.policy_outlined),
            title: const Text('Ask VirusTotal about flagged files and links'),
            subtitle: Text(
              widget.services.virusTotal.enabled
                  ? 'On, with your API key. Offered for risky attachments and suspicious '
                        'links, only when you tap "Check with VirusTotal".'
                  : 'Off.',
            ),
            value: widget.services.virusTotal.enabled,
            onChanged: _setVirusTotal,
          ),
          const _Group('Senders and devices'),
          DeviceSyncTile(services: widget.services),
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Images'),
            subtitle: const Text('Senders whose images load automatically'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImageSendersPage(services: widget.services),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked senders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BlockedSendersPage(services: widget.services),
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.dns_outlined),
            title: const Text('Rules on the mail server'),
            subtitle: const Text(
              'Blocked senders and folder rules also run on your mail server, so mail is sorted '
              'even when $appName isn\'t open. Only where the server supports it (Sieve); a '
              'filter you already use there is never replaced.',
            ),
            value: settings.serverRules,
            onChanged: _setServerRules,
          ),
          if (settings.serverRules)
            for (final account in widget.services.store.accounts.all())
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                title: Text(account.email),
                subtitle: Text(
                  serverRulesText(
                    ServerRules.statusOf(widget.services.store, account.id),
                  ),
                ),
              ),
          const _Group('About'),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Privacy'),
            subtitle: Text(
              '$appName has no servers and collects nothing. Mail is stored encrypted on this '
              'device and goes only to your own mail servers. Remote images and trackers are '
              'blocked.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Licences'),
            subtitle: Text(
              '$appName is free software under the Mozilla Public License 2.0.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                showLicensePage(context: context, applicationName: appName),
          ),
        ],
      ),
    );
  }
}

/// A heading that names a group of settings.
final class _Group extends StatelessWidget {
  const _Group(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
        child: Text(
          text,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Asks before Google Safe Browsing is turned on: what it does, what is
/// sent, and (for builds without one) the user's own API key.
final class SafeBrowsingDialog extends StatefulWidget {
  const SafeBrowsingDialog({super.key, required this.safety});

  final LinkSafety safety;

  @override
  State<SafeBrowsingDialog> createState() => _SafeBrowsingDialogState();
}

final class _SafeBrowsingDialogState extends State<SafeBrowsingDialog> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _turnOn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await widget.safety.enable(ownKey: _key.text);
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Check links with Google Safe Browsing?'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '$appName downloads Google\'s lists of dangerous sites and checks links you open '
            'against them on this device. Only when a link looks like one on the lists is a '
            'short piece of its fingerprint sent to Google to confirm; the link itself never is. '
            'Google sees your IP address when the lists are downloaded.',
          ),
          if (!widget.safety.hasBuiltInKey) ...[
            const SizedBox(height: 16),
            const Text(
              'This copy of $appName needs your own Google API key with the Safe Browsing API '
              'turned on (free, from Google Cloud). It stays in this device\'s keychain.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'API key',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('Downloading the lists…'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _turnOn,
        child: const Text('Turn on'),
      ),
    ],
  );
}

/// Asks before VirusTotal is turned on: what is sent, and the user's key.
final class VirusTotalDialog extends StatefulWidget {
  const VirusTotalDialog({super.key, required this.checks});

  final VirusTotalChecks checks;

  @override
  State<VirusTotalDialog> createState() => _VirusTotalDialogState();
}

final class _VirusTotalDialogState extends State<VirusTotalDialog> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _turnOn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await widget.checks.enable(_key.text);
    if (!mounted) return;
    if (problem == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Ask VirusTotal?'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'When $appName flags an attachment or a link as risky, it can ask VirusTotal what '
            'dozens of security vendors think of it, only when you tap "Check with VirusTotal".',
          ),
          const SizedBox(height: 8),
          const Text(
            'For a file, only its fingerprint (SHA-256) is sent; the file never is. For a link, '
            'the address itself is sent. VirusTotal (Google) keeps what it is asked and sees your '
            'IP address.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Use your own free API key from virustotal.com (your profile, "API key"). It stays in '
            'this device\'s keychain.',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'API key',
              border: OutlineInputBorder(),
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _turnOn,
        child: const Text('Turn on'),
      ),
    ],
  );
}
