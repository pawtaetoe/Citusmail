// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart' show appName;
import '../background/background_mail.dart';
import '../services/app_services.dart';

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

  @override
  Widget build(BuildContext context) {
    final settings = widget.services.settings;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
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
            const Divider(),
            SwitchListTile(
              title: const Text('Instant mail'),
              subtitle: const Text(
                'Keeps a live connection to your mail server so new mail arrives at once. '
                'Android requires a permanent "Fmail is connected" notification and it uses more '
                'battery. When off, Fmail checks about every 15 minutes.',
              ),
              value: settings.instantMail,
              onChanged: _setInstant,
            ),
          ],
          const Divider(),
          ListTile(
            title: const Text('Privacy'),
            subtitle: Text(
              '$appName has no servers and collects nothing. Mail is stored encrypted on this '
              'device and goes only to your own mail servers. Remote images and trackers are '
              'blocked.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          ListTile(
            title: const Text('About'),
            subtitle: Text(
              '$appName is free software under the Mozilla Public License 2.0.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            onTap: () =>
                showLicensePage(context: context, applicationName: appName),
          ),
        ],
      ),
    );
  }
}
