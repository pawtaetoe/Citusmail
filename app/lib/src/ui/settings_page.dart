// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;
import '../background/background_mail.dart';
import '../mail/corrections.dart';
import '../mail/mail_controller.dart';
import '../security/app_lock.dart';
import '../security/pin_dialogs.dart';
import '../services/app_services.dart';
import '../services/link_safety.dart';
import '../services/virus_total_checks.dart';
import 'block_dialog.dart';
import 'code_cleanup_banner.dart';
import 'device_sync_page.dart';
import 'image_senders_page.dart';
import 'link_opener.dart';
import 'privacy_report_page.dart';
import 'screener_page.dart';
import 'sender_cleanup_page.dart';

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
  const SettingsPage({
    super.key,
    required this.services,
    this.controller,
    this.isAndroid,
    this.onShowMail,
    this.batteryLimited = BackgroundMail.batteryLimited,
  });

  final AppServices services;

  /// The mail screen, for pages that act on mail (Clean up).
  final MailController? controller;

  /// Shows mail matching a search (from the Privacy report's senders).
  final void Function(String query)? onShowMail;

  /// Overrides the platform (tests).
  final bool? isAndroid;

  /// Whether Android holds background checks back to save battery.
  final Future<bool> Function() batteryLimited;

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

  /// Old codes leave the inbox. Choosing an age here is the user's OK
  /// (otherwise the Verification section asks first).
  Widget _codeCleanupTile() {
    final cleanup = CodeCleanupSettings(widget.services.store);
    final age = cleanup.age;
    final choice = age == CodeCleanupAge.off
        ? CodeCleanupText.age(age)
        : '${CodeCleanupText.age(age)}: '
              '${CodeCleanupText.action(cleanup.action)}';
    final waiting = age != CodeCleanupAge.off && !cleanup.agreed;
    return ListTile(
      leading: const Icon(Icons.auto_delete_outlined),
      title: const Text('Clean up old codes'),
      subtitle: Text(
        '$choice. ${CodeCleanupText.explanation}'
        '${waiting ? ' Not on yet: the Verification section asks you first.' : ''}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await showDialog<void>(
          context: context,
          builder: (_) => _CodeCleanupDialog(settings: cleanup),
        );
        if (mounted) setState(() {});
      },
    );
  }

  /// First-time senders wait for the user's OK; where screened-out mail
  /// goes; and every decision, to change later.
  List<Widget> _screenerSettings() {
    final screener = widget.services.store.screener;
    final decided = screener.all().length;
    void changed() {
      setState(() {});
      widget.controller?.refresh();
    }

    return [
      SwitchListTile(
        secondary: const Icon(Icons.how_to_reg_outlined),
        title: const Text('Screen first-time senders'),
        subtitle: const Text(
          'Someone writing for the first time waits in the Screener, at the '
          'top of your inbox, until you let them in. Everyone you already '
          'have mail from is let in. Codes and replies to you always come '
          'straight in.',
        ),
        value: screener.enabled,
        onChanged: (on) {
          on ? screener.enable() : screener.disable();
          changed();
        },
      ),
      if (screener.enabled)
        ListTile(
          contentPadding: const EdgeInsets.only(left: 72, right: 16),
          title: const Text('Screened-out mail goes to'),
          subtitle: const Text('Never deleted, never Junk'),
          trailing: DropdownButton<ScreenOutPlace>(
            value: screener.outPlace,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(
                value: ScreenOutPlace.newsletters,
                child: Text('Newsletters'),
              ),
              DropdownMenuItem(
                value: ScreenOutPlace.notifications,
                child: Text('Notifications'),
              ),
              DropdownMenuItem(
                value: ScreenOutPlace.archive,
                child: Text('Archive'),
              ),
            ],
            onChanged: (place) {
              if (place == null) return;
              screener.outPlace = place;
              changed();
            },
          ),
        ),
      ListTile(
        leading: const Icon(Icons.rule),
        title: const Text('Screened senders'),
        subtitle: Text(
          decided == 0
              ? 'Senders you let in or screened out'
              : '$decided ${decided == 1 ? 'sender' : 'senders'} you let in or screened out',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ScreenedSendersPage(
                services: widget.services,
                controller: widget.controller,
              ),
            ),
          );
          if (mounted) setState(() {});
        },
      ),
    ];
  }

  Future<void> _setInstant(bool on) async {
    setState(() => widget.services.settings.instantMail = on);
    try {
      await BackgroundMail.setInstant(on);
      if (on && await widget.batteryLimited()) {
        await BackgroundMail.askToRunInBackground();
      }
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

  static String _keepLabel(KeepMail keep) => switch (keep) {
    KeepMail.threeMonths => 'The last 3 months',
    KeepMail.year => 'The last year',
    KeepMail.twoYears => 'The last 2 years',
    KeepMail.everything => 'Everything',
  };

  /// How far back mail is downloaded (headers and previews; whole
  /// messages when opened). Going further back fills in over the next
  /// checks for mail.
  Future<void> _chooseKeepMail() async {
    final store = widget.services.store;
    final current = KeepMail.read(store);
    final chosen = await showDialog<KeepMail>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Keep mail from'),
        children: [
          RadioGroup<KeepMail>(
            groupValue: current,
            onChanged: (k) => Navigator.pop(context, k),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final k in KeepMail.values)
                  RadioListTile<KeepMail>(
                    value: k,
                    title: Text(_keepLabel(k)),
                    subtitle: k == KeepMail.everything
                        ? const Text('Uses more space on large mailboxes')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (chosen == null || chosen == current) return;
    store.settings.write(KeepMail.key, chosen.storageName);
    setState(() {});
    try {
      await widget.services.worker.syncNow();
    } on SyncWorkerException {
      // Filled in with the next check for mail.
    }
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
              'One for each new email in Verification, Important, General and '
              'Notifications, with a Copy code button for codes. Newsletters '
              'never notify. '
              'The lock screen shows only that there is new mail.',
            ),
            value: settings.notifications,
            onChanged: (on) => setState(() => settings.notifications = on),
          ),
          SwitchListTile(
            title: const Text('Also for Notifications'),
            subtitle: const Text(
              'Emails from services such as GitHub, your bank or a delivery '
              'company. Turn off to notify only for mail from people.',
            ),
            value:
                settings.notifications && settings.notifyNotificationsSection,
            onChanged: settings.notifications
                ? (on) =>
                      setState(() => settings.notifyNotificationsSection = on)
                : null,
          ),
          SwitchListTile(
            title: const Text('Show message previews'),
            subtitle: const Text(
              'The first lines of each email under its subject. When off, '
              'notifications show only the sender and the subject.',
            ),
            value: settings.notifications && settings.notificationPreviews,
            onChanged: settings.notifications
                ? (on) => setState(() => settings.notificationPreviews = on)
                : null,
          ),
          SwitchListTile(
            title: const Text('Bill and trial reminders'),
            subtitle: const Text(
              'A few days before a bill is due, a free trial starts charging, '
              'a yearly subscription renews or a return window closes, found '
              'in your mail on this device. Also listed under Subscriptions '
              'and Deliveries.',
            ),
            value: settings.notifications && settings.reminders,
            onChanged: settings.notifications
                ? (on) => setState(() => settings.reminders = on)
                : null,
          ),
          SwitchListTile(
            title: const Text('Also remind me of monthly renewals'),
            subtitle: const Text(
              'Subscriptions you pay every month, not just yearly ones.',
            ),
            value: settings.monthlyRenewals,
            onChanged: (on) => setState(() => settings.monthlyRenewals = on),
          ),
          SwitchListTile(
            title: const Text('Follow-up reminders'),
            subtitle: const Text(
              'When nobody has answered an email you sent with “Remind me if '
              'no reply” by the time you chose. It comes back to the top of '
              'your inbox either way.',
            ),
            value: settings.notifications && settings.followUpNotifications,
            onChanged: settings.notifications
                ? (on) => setState(() => settings.followUpNotifications = on)
                : null,
          ),
          if (_android)
            SwitchListTile(
              title: const Text('Instant mail'),
              subtitle: const Text(
                'Keeps a live connection to your mail server so new mail arrives at once, '
                'also while your phone sleeps. Android requires a quiet, permanent '
                '"$appName is connected" notification, and it uses a little more battery. '
                'When off, $appName checks about every 5 minutes, or less often when Android '
                'saves battery.',
              ),
              value: settings.instantMail,
              onChanged: _setInstant,
            ),
          if (_android && !settings.instantMail)
            _BackgroundChecks(
              store: widget.services.store,
              batteryLimited: widget.batteryLimited,
            ),
          const _Group('Inbox'),
          SwitchListTile(
            secondary: const Icon(Icons.waving_hand_outlined),
            title: const Text('New since you were away'),
            subtitle: const Text(
              'When you come back to the app, the emails that arrived while '
              'you were away are shown together at the top of your inbox.',
            ),
            value: settings.newSinceAway,
            onChanged: (on) {
              setState(() => settings.newSinceAway = on);
              widget.controller?.refresh();
            },
          ),
          const _Group('Screener'),
          ..._screenerSettings(),
          const _Group('Mail on this device'),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Keep mail from'),
            subtitle: Text(
              '${_keepLabel(KeepMail.read(widget.services.store))}. Older mail '
              'still loads when you scroll down. Search and Subscriptions see '
              'what is on this device.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _chooseKeepMail,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.receipt_long_outlined),
            title: const Text('Read receipts and bookings automatically'),
            subtitle: const Text(
              'Downloads receipts, bills and booking emails from your mail '
              'server so Subscriptions, Deliveries and Trips fill in by '
              'themselves. They stay unread.',
            ),
            value: settings.autoRead,
            onChanged: (on) {
              setState(() => settings.autoRead = on);
              if (on) widget.services.autoRead.request();
            },
          ),
          const _Group('Security'),
          ..._lockSettings(),
          const _Group('Senders and devices'),
          if (widget.controller case final controller?)
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('Clean up senders'),
              subtitle: const Text(
                'Senders you rarely open, and how to stop their mail',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SenderCleanupPage(controller: controller),
                ),
              ),
            ),
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
          const _Group('Verification codes'),
          _codeCleanupTile(),
          const _Group('About'),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Privacy'),
            subtitle: Text(
              '$appName has no servers and collects nothing. Mail is stored encrypted on this '
              'device and goes only to your own mail servers. Remote images and trackers are '
              'blocked. See what was kept from senders in the Privacy report.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PrivacyReportPage(
                  services: widget.services,
                  onShowMail: widget.onShowMail,
                ),
              ),
            ),
          ),
          _WebPageTile(
            icon: Icons.policy_outlined,
            title: 'Privacy policy',
            page: privacyPolicyUrl,
          ),
          _WebPageTile(
            icon: Icons.description_outlined,
            title: 'Terms of service',
            page: termsOfServiceUrl,
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
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Advanced'),
            subtitle: const Text(
              'Outside link and file checks, rules on your mail server',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AdvancedSettingsPage(services: widget.services),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings for people who want more: checks by outside services (with
/// their own API keys) and rules on the mail server. Kept off the main
/// Settings page so it stays simple.
final class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({super.key, required this.services});

  final AppServices services;

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

final class _AdvancedSettingsPageState extends State<AdvancedSettingsPage> {
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

  /// "Forget what it learned", after asking.
  Future<void> _forget() async {
    final forget = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget what it learned?'),
        content: const Text(
          'Things that were left out because they looked like ones you '
          'corrected are listed again. The ones you marked yourself stay '
          'hidden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (forget != true || !mounted) return;
    setState(() => Corrections(widget.services.store).forget());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Forgot what it learned'), persist: false),
      );
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
      appBar: AppBar(title: const Text('Advanced')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Outside services and rules on the server are off unless you '
              'turn them on, and $appName works fully without them.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const _Group('Checks by outside services'),
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
          const _Group('Mail server'),
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
          const _Group('Subscriptions, deliveries, trips and accounts'),
          SwitchListTile(
            secondary: const Icon(Icons.school_outlined),
            title: const Text('Learn from my corrections'),
            subtitle: const Text(
              'When you say something isn\'t a subscription, delivery, '
              'booking or account, similar ones are left out too. Learned on '
              'this device, only from your own choices.',
            ),
            value: settings.learnFromCorrections,
            onChanged: (on) =>
                setState(() => settings.learnFromCorrections = on),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Forget what it learned'),
            subtitle: const Text(
              'Lists everything as it was found again. What you marked '
              'yourself stays hidden.',
            ),
            enabled: Corrections(widget.services.store).learnedAnything,
            onTap: _forget,
          ),
        ],
      ),
    );
  }
}

/// A heading that names a group of settings.
/// How old codes get before they are cleaned up, and where they go.
final class _CodeCleanupDialog extends StatefulWidget {
  const _CodeCleanupDialog({required this.settings});

  final CodeCleanupSettings settings;

  @override
  State<_CodeCleanupDialog> createState() => _CodeCleanupDialogState();
}

final class _CodeCleanupDialogState extends State<_CodeCleanupDialog> {
  CodeCleanupSettings get _settings => widget.settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final age = _settings.age;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
    return AlertDialog(
      title: const Text('Clean up old codes'),
      contentPadding: const EdgeInsets.only(top: 12, bottom: 8),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                CodeCleanupText.explanation,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            heading('When'),
            RadioGroup<CodeCleanupAge>(
              groupValue: age,
              onChanged: (a) {
                if (a == null) return;
                setState(() {
                  _settings.age = a;
                  if (a != CodeCleanupAge.off) _settings.agree();
                });
              },
              child: Column(
                children: [
                  for (final a in CodeCleanupAge.values)
                    RadioListTile<CodeCleanupAge>(
                      value: a,
                      title: Text(CodeCleanupText.age(a)),
                    ),
                ],
              ),
            ),
            if (age != CodeCleanupAge.off) ...[
              heading('What happens'),
              RadioGroup<CodeCleanupAction>(
                groupValue: _settings.action,
                onChanged: (a) {
                  if (a != null) setState(() => _settings.action = a);
                },
                child: Column(
                  children: [
                    for (final a in CodeCleanupAction.values)
                      RadioListTile<CodeCleanupAction>(
                        value: a,
                        title: Text(CodeCleanupText.action(a)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

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

/// The privacy policy on the app's website (also in docs/privacy-policy.md).
final privacyPolicyUrl = Uri.parse(
  'https://citusmail.fluminaris.com/privacy-policy',
);

/// The terms of service on the app's website (docs/terms-of-service.md).
final termsOfServiceUrl = Uri.parse(
  'https://citusmail.fluminaris.com/terms-of-service',
);

/// A page on the app's website, opened in the browser after the usual
/// "Open this link?" question.
final class _WebPageTile extends StatelessWidget {
  const _WebPageTile({
    required this.icon,
    required this.title,
    required this.page,
  });

  final IconData icon;
  final String title;
  final Uri page;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(
      '${page.host}${page.path}',
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
    trailing: const Icon(Icons.open_in_new),
    onTap: () => LinkOpener.open(context, page, onMailto: (_) {}),
  );
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

/// When the background check last ran, and, if Android holds it back to
/// save battery, a way to allow it (the app's page in Android's settings).
final class _BackgroundChecks extends StatefulWidget {
  const _BackgroundChecks({required this.store, required this.batteryLimited});

  final MailStore store;
  final Future<bool> Function() batteryLimited;

  @override
  State<_BackgroundChecks> createState() => _BackgroundChecksState();
}

final class _BackgroundChecksState extends State<_BackgroundChecks> {
  bool _limited = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _check();
    // Back from Android's settings: look again.
    _lifecycle = AppLifecycleListener(onResume: _check);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final limited = await widget.batteryLimited();
    if (mounted) setState(() => _limited = limited);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = BackgroundMail.lastCheck(widget.store);
    final lastText = switch (last) {
      null => 'No background check has run yet.',
      (:final at, ok: true) => 'Last background check: ${_ago(at)}.',
      (:final at, ok: false) =>
        'Last background check: ${_ago(at)}, but not every account could be '
            'reached.',
    };
    return ListTile(
      leading: const Icon(Icons.schedule),
      title: const Text('Background checks'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _limited
                ? '$lastText Android is saving battery for $appName, so '
                      'checks can wait until you open the app.'
                : lastText,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (_limited)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: BackgroundMail.askToRunInBackground,
                child: const Text('Allow in background'),
              ),
            ),
        ],
      ),
    );
  }

  static String _ago(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '$minutes min ago';
    final hours = minutes ~/ 60;
    if (hours < 24) return hours == 1 ? '1 hour ago' : '$hours hours ago';
    final days = hours ~/ 24;
    return days == 1 ? 'yesterday' : '$days days ago';
  }
}
