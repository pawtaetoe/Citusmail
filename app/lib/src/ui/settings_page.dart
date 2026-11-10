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
import '../pairing/receive_accounts_page.dart';
import '../pairing/send_accounts_page.dart';
import '../security/app_lock.dart';
import '../security/pin_dialogs.dart';
import '../services/app_services.dart';
import '../services/link_safety.dart';
import '../services/virus_total_checks.dart';
import 'app_icons.dart';
import 'appearance.dart';
import 'block_dialog.dart';
import 'code_cleanup_banner.dart';
import 'device_sync_page.dart';
import 'discover_page.dart';
import 'feature_settings.dart';
import 'image_senders_page.dart';
import 'link_opener.dart';
import 'page_scaffold.dart';
import 'privacy_report_page.dart';
import 'settings_catalog.dart';
import 'sign_offs_page.dart';
import 'tips.dart';
import 'whats_new.dart';

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

/// App settings, grouped by what people want to do ([SettingsCatalog]),
/// with a search that knows other words for them ("dark mode", "PIN").
///
/// Phones list the groups, each on a page of its own; wider screens show
/// the groups beside all the settings, which scroll as one.
final class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.services,
    this.controller,
    this.isAndroid,
    this.onShowMail,
    this.onAddAccount,
    this.show,
    this.batteryLimited = BackgroundMail.batteryLimited,
  });

  final AppServices services;

  /// The mail screen, refreshed after settings that change what it shows
  /// (the Screener, mail that came while you were away).
  final MailController? controller;

  /// Shows mail matching a search (from the Privacy report's senders).
  final void Function(String query)? onShowMail;

  /// Starts adding an account (Accounts, "Add account").
  final VoidCallback? onAddAccount;

  /// A setting to show and mark on opening: a [SettingEntry.id], so a
  /// feature can open its own setting.
  final String? show;

  /// Overrides the platform (tests).
  final bool? isAndroid;

  /// Whether Android holds background checks back to save battery.
  final Future<bool> Function() batteryLimited;

  /// From this width the groups and the settings are side by side.
  static const twoPaneWidth = 720.0;

  /// Opens Settings, showing the setting [show] if given.
  static Future<void> open(
    BuildContext context, {
    required MailController controller,
    String? show,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsPage(
        services: controller.services,
        controller: controller,
        onShowMail: controller.search,
        show: show,
      ),
    ),
  );

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends State<SettingsPage> {
  bool get _android => widget.isAndroid ?? Platform.isAndroid;

  AppLock get _lock => widget.services.lock;
  bool _biometricsAvailable = false;

  /// Where each setting and group is, to scroll to it.
  final _anchors = <String, GlobalKey>{};
  final _content = GlobalKey();
  final _scroll = ScrollController();

  /// Rebuilds a group's own page (phones) when a setting changes.
  final _revision = ValueNotifier(0);

  /// The setting found by a search (or [SettingsPage.show]), marked.
  String? _highlight;

  /// The group in view (wide screens).
  String _current = SettingsCatalog.sections.first.id;

  /// The group just chosen: kept while the page scrolls to it.
  String? _target;

  /// Whether the groups and the settings are side by side (as last laid
  /// out: the page's own width, not the window's).
  bool _twoPane = false;

  @override
  void initState() {
    super.initState();
    widget.services.settings.syncedChanges.addListener(_syncedElsewhere);
    _lock.biometrics.isAvailable().then((available) {
      if (mounted) setState(() => _biometricsAvailable = available);
    });
    if (widget.show case final id?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal(id);
      });
    }
  }

  @override
  void dispose() {
    widget.services.settings.syncedChanges.removeListener(_syncedElsewhere);
    _scroll.dispose();
    _revision.dispose();
    super.dispose();
  }

  /// A preference changed on another device and was applied here.
  void _syncedElsewhere() {
    if (mounted) setState(() {});
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

  GlobalKey _key(String id) =>
      _anchors.putIfAbsent(id, () => GlobalKey(debugLabel: id));

  /// Whether tiles are being built for a group's own page (phones), which
  /// may be open while the window grows wide: its tiles have keys of
  /// their own.
  bool _onPage = false;

  /// [tile], findable by the search as [id].
  Widget _find(String id, Widget tile) =>
      _onPage ? _findOnPage(id, tile) : _findHere(id, tile);

  Widget _findHere(String id, Widget tile) => KeyedSubtree(
    key: _key(id),
    child: SettingHighlight(on: _highlight == id, child: tile),
  );

  Widget _findOnPage(String id, Widget tile) => KeyedSubtree(
    key: _key('page:$id'),
    child: SettingHighlight(on: _highlight == id, child: tile),
  );

  // ------------------------------------------------------------ search

  Future<void> _search() async {
    final route = _twoPane
        ? DialogRoute<String>(
            context: context,
            builder: (_) => Dialog(
              alignment: Alignment.topCenter,
              insetPadding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
              child: SizedBox(
                width: 560,
                height: 480,
                child: _SettingsSearch(
                  android: _android,
                  canDiscover: widget.controller != null,
                ),
              ),
            ),
          )
        : MaterialPageRoute<String>(
            fullscreenDialog: true,
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Search settings')),
              body: _SettingsSearch(
                android: _android,
                canDiscover: widget.controller != null,
              ),
            ),
          );
    final id = await Navigator.of(context).push(route);
    if (id == null || !mounted) return;
    if (id == _SettingsSearch.discover) {
      _openDiscover();
    } else {
      _reveal(id);
    }
  }

  /// Scrolls to setting [id] (on phones, opens its group) and marks it.
  void _reveal(String id) {
    final entry = SettingsCatalog.available(android: _android)
        .where((e) => e.id == id)
        .firstOrNull;
    final section = entry?.section ?? id;
    if (entry != null && entry.advanced) {
      _openAdvanced(highlight: id);
      return;
    }
    if (!SettingsCatalog.sections.any((s) => s.id == section)) return;
    setState(() => _highlight = id);
    if (!_twoPane) {
      _openSection(section, reveal: id);
      return;
    }
    setState(() {
      _current = section;
      _target = section;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target =
          _anchors[id]?.currentContext ??
          _anchors['section:$section']?.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.2,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ------------------------------------------------------- navigation

  void _jump(String section) {
    setState(() {
      _current = section;
      _target = section;
      _highlight = null;
    });
    final target = _anchors['section:$section']?.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  /// Wide screens: the group whose heading was last scrolled past.
  bool _scrolled(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _target = null;
    }
    if (n is! ScrollUpdateNotification || _target != null) return false;
    final view = _content.currentContext?.findRenderObject() as RenderBox?;
    if (view == null) return false;
    final top = view.localToGlobal(Offset.zero).dy;
    var current = SettingsCatalog.sections.first.id;
    for (final s in SettingsCatalog.sections) {
      final box =
          _anchors['section:${s.id}']?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null) continue;
      if (box.localToGlobal(Offset.zero).dy - top <= 48) current = s.id;
    }
    if (current != _current) setState(() => _current = current);
    return false;
  }

  /// Phones: one group's settings on a page of their own.
  void _openSection(String section, {String? reveal}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => _SectionPage(
              page: this,
              section: SettingsCatalog.section(section),
              reveal: reveal,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() => _highlight = null);
        });
  }

  void _openAdvanced({String? highlight}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          AdvancedSettingsPage(services: widget.services, highlight: highlight),
    ),
  );

  void _openDiscover() {
    final controller = widget.controller;
    if (controller == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverPage(controller: controller),
      ),
    );
  }

  // ------------------------------------------------- settings actions

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

  Future<void> _setInstant(bool on) async {
    setState(() => widget.services.settings.instantMail = on);
    await InstantMail.turn(
      context,
      widget.services,
      on,
      batteryLimited: widget.batteryLimited,
    );
    if (mounted) setState(() {});
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

  Future<void> _addFromPhone() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReceiveAccountsPage(services: widget.services),
      ),
    );
    if (added == true) widget.controller?.refresh();
  }

  void _openPrivacyReport() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PrivacyReportPage(
        services: widget.services,
        onShowMail: widget.onShowMail,
      ),
    ),
  );

  // ----------------------------------------------------- the settings

  /// The settings of group [section], in order ([onPage]: for its own
  /// page).
  List<Widget> _tiles(String section, {bool onPage = false}) {
    _onPage = onPage;
    try {
      return switch (section) {
        'notifications' => _notificationSettings(),
        'inbox' => _inboxSettings(),
        'writing' => _writingSettings(),
        'accounts' => _accountSettings(),
        'privacy' => _privacySettings(),
        'devices' => _deviceSettings(),
        'appearance' => _appearanceSettings(),
        'about' => _aboutSettings(),
        _ => const [],
      };
    } finally {
      _onPage = false;
    }
  }

  List<Widget> _notificationSettings() {
    final settings = widget.services.settings;
    return [
      _find(
        'notifications',
        SwitchListTile(
          title: const Text('New mail notifications'),
          subtitle: const SettingExplained(
            'One for each new email; newsletters never notify',
            more:
                'For new mail in Verification, Important, General and '
                'Notifications, with a Copy code button for codes. The '
                'lock screen shows only that there is new mail.',
          ),
          value: settings.notifications,
          onChanged: (on) => setState(() => settings.notifications = on),
        ),
      ),
      _find(
        'notifyServices',
        SwitchListTile(
          title: const Text('Also for Notifications'),
          subtitle: const SettingExplained(
            'Mail from services such as your bank or GitHub',
            more:
                'Emails from services such as GitHub, your bank or a '
                'delivery company. Turn off to notify only for mail from '
                'people.',
          ),
          value: settings.notifications && settings.notifyNotificationsSection,
          onChanged: settings.notifications
              ? (on) => setState(() => settings.notifyNotificationsSection = on)
              : null,
        ),
      ),
      _find(
        'previews',
        SwitchListTile(
          title: const Text('Show message previews'),
          subtitle: const SettingExplained(
            'The first lines of each email, in the notification',
            more:
                'When off, notifications show only the sender and the '
                'subject.',
          ),
          value: settings.notifications && settings.notificationPreviews,
          onChanged: settings.notifications
              ? (on) => setState(() => settings.notificationPreviews = on)
              : null,
        ),
      ),
      _find(
        'reminders',
        SwitchListTile(
          title: const Text('Bill and trial reminders'),
          subtitle: const SettingExplained(
            'A few days before a bill is due or a trial ends',
            more:
                'Also before a free trial starts charging, a yearly '
                'subscription renews or a return window closes, and the '
                'day before an appointment. Found in your mail on this '
                'device.',
          ),
          value: settings.notifications && settings.reminders,
          onChanged: settings.notifications
              ? (on) => setState(() => settings.reminders = on)
              : null,
        ),
      ),
      _find(
        'monthlyRenewals',
        SwitchListTile(
          title: const Text('Also remind me of monthly renewals'),
          subtitle: const Text(
            'Subscriptions you pay every month, not just yearly ones.',
          ),
          value: settings.monthlyRenewals,
          onChanged: (on) => setState(() => settings.monthlyRenewals = on),
        ),
      ),
      _find(
        'followUps',
        SwitchListTile(
          title: const Text('Follow-up reminders'),
          subtitle: const SettingExplained(
            'When nobody has replied by the time you chose',
            more:
                'For emails you sent with “Remind me if no reply”. The '
                'email comes back to the top of your inbox either way.',
          ),
          value: settings.notifications && settings.followUpNotifications,
          onChanged: settings.notifications
              ? (on) => setState(() => settings.followUpNotifications = on)
              : null,
        ),
      ),
      if (_android)
        _find(
          'instantMail',
          SwitchListTile(
            title: const Text('Instant mail'),
            subtitle: const SettingExplained(
              'New mail at once, also while your phone sleeps',
              more:
                  'Keeps a live connection to your mail server. Android '
                  'requires a quiet, permanent "$appName is connected" '
                  'notification, and it uses a little more battery. When '
                  'off, $appName checks about every 5 minutes, or less '
                  'often when Android saves battery.',
            ),
            value: settings.instantMail,
            onChanged: _setInstant,
          ),
        ),
      if (_android && !settings.instantMail)
        _find(
          'backgroundChecks',
          _BackgroundChecks(
            store: widget.services.store,
            batteryLimited: widget.batteryLimited,
          ),
        ),
    ];
  }

  List<Widget> _inboxSettings() {
    final settings = widget.services.settings;
    return [
      _find(
        'newSinceAway',
        SwitchListTile(
          secondary: const Icon(Icons.waving_hand_outlined),
          title: const Text('New since you were away'),
          subtitle: const SettingExplained(
            'Mail that came while you were away, together at the top',
            more:
                'When you come back to the app, the emails that arrived '
                'while you were away are shown together at the top of your '
                'inbox.',
          ),
          value: settings.newSinceAway,
          onChanged: (on) {
            setState(() => settings.newSinceAway = on);
            widget.controller?.refresh();
          },
        ),
      ),
      ScreenerSettings(
        services: widget.services,
        controller: widget.controller,
        wrap: _onPage ? _findOnPage : _findHere,
      ),
      _find(
        'autoRead',
        SwitchListTile(
          secondary: const Icon(Icons.receipt_long_outlined),
          title: const Text('Read receipts and bookings automatically'),
          subtitle: const SettingExplained(
            'So Subscriptions, Deliveries and Trips fill in by themselves',
            more:
                'Downloads receipts, bills and booking emails from your '
                'mail server. They stay unread.',
          ),
          value: settings.autoRead,
          onChanged: (on) {
            setState(() => settings.autoRead = on);
            if (on) widget.services.autoRead.request();
          },
        ),
      ),
      _find('codeCleanup', _codeCleanupTile()),
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
      subtitle: SettingExplained(
        '$choice.'
        '${waiting ? ' Verification asks you first.' : ''}',
        more: CodeCleanupText.explanation,
      ),
      trailing: const Icon(AppIcons.chevron),
      onTap: () async {
        await showDialog<void>(
          context: context,
          builder: (_) => _CodeCleanupDialog(settings: cleanup),
        );
        if (mounted) setState(() {});
      },
    );
  }

  List<Widget> _writingSettings() => [
    _find(
      'writing',
      const ListTile(
        leading: Icon(AppIcons.sendLater),
        title: Text('Send later, reminders and read receipts'),
        subtitle: Text('In the new message window, next to Send'),
      ),
    ),
    _find(
      'signOffs',
      ListTile(
        leading: const Icon(signOffIcon),
        title: const Text('Sign-offs'),
        subtitle: const Text(
          'The text that ends your emails, like a signature',
        ),
        trailing: const Icon(AppIcons.chevron),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SignOffsPage(services: widget.services),
          ),
        ),
      ),
    ),
  ];

  List<Widget> _accountSettings() => [
    for (final (i, account) in widget.services.store.accounts.all().indexed)
      _find(
        i == 0 ? 'accounts' : 'account-${account.id}',
        ListTile(
          leading: const Icon(Icons.alternate_email),
          title: Text(account.email),
          subtitle: const Text('Folders, password, remove: ⋮ in the sidebar'),
        ),
      ),
    if (widget.onAddAccount case final add?)
      _find(
        'addAccount',
        ListTile(
          leading: const Icon(AppIcons.addAccount),
          title: const Text('Add account'),
          trailing: const Icon(AppIcons.chevron),
          onTap: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            add();
          },
        ),
      ),
    _find(
      'keepMail',
      ListTile(
        leading: const Icon(Icons.history),
        title: const Text('Keep mail from'),
        subtitle: SettingExplained(
          '${_keepLabel(KeepMail.read(widget.services.store))}.',
          more:
              'Older mail still loads when you scroll down. Search and '
              'Subscriptions see what is on this device.',
        ),
        trailing: const Icon(AppIcons.chevron),
        onTap: _chooseKeepMail,
      ),
    ),
  ];

  List<Widget> _privacySettings() {
    final enabled = _lock.enabled;
    return [
      _find(
        'appLock',
        SwitchListTile(
          secondary: const Icon(AppIcons.lock),
          title: const Text('App lock'),
          subtitle: const SettingExplained(
            'Ask for a PIN to open $appName',
            more:
                'While locked, notifications show only that there is new '
                'mail.',
          ),
          value: enabled,
          onChanged: _setLock,
        ),
      ),
      if (enabled) ...[
        _find(
          'lockAfter',
          ListTile(
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
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
        ),
        if (_biometricsAvailable)
          _find(
            'biometrics',
            SwitchListTile(
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              title: Text('Unlock with ${_lock.biometrics.name}'),
              value: _lock.useBiometrics,
              onChanged: _setBiometrics,
            ),
          ),
        _find(
          'changePin',
          ListTile(
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            title: const Text('Change PIN'),
            onTap: _changePin,
          ),
        ),
      ],
      _find(
        'images',
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: const Text('Images'),
          subtitle: const Text('Senders whose images load automatically'),
          trailing: const Icon(AppIcons.chevron),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ImageSendersPage(services: widget.services),
            ),
          ),
        ),
      ),
      _find(
        'blockedSenders',
        ListTile(
          leading: const Icon(AppIcons.block),
          title: const Text('Blocked senders'),
          subtitle: const Text('Their mail goes straight to Junk'),
          trailing: const Icon(AppIcons.chevron),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => BlockedSendersPage(services: widget.services),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _deviceSettings() => [
    _find('deviceSync', DeviceSyncTile(services: widget.services)),
    if (_android)
      _find(
        'pairing',
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: const Text('Send accounts to a computer'),
          subtitle: const Text(
            'Scan the code on your computer to sign in there',
          ),
          trailing: const Icon(AppIcons.chevron),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SendAccountsPage(services: widget.services),
            ),
          ),
        ),
      )
    else if (widget.isAndroid != null || ReceiveAccountsPage.supported)
      _find(
        'pairing',
        ListTile(
          leading: const Icon(Icons.qr_code_2),
          title: const Text('Add accounts from your phone'),
          subtitle: const Text('Scan a code with $appName on your phone'),
          trailing: const Icon(AppIcons.chevron),
          onTap: _addFromPhone,
        ),
      ),
  ];

  List<Widget> _appearanceSettings() {
    final store = widget.services.store;
    return [
      _find(
        'theme',
        ListTile(
          leading: const Icon(Icons.dark_mode_outlined),
          title: const Text('Theme'),
          subtitle: const Text('Light, dark, or as your device is set'),
          trailing: DropdownButton<ThemeMode>(
            value: Appearance.read(store),
            underline: const SizedBox.shrink(),
            items: [
              for (final mode in [
                ThemeMode.system,
                ThemeMode.light,
                ThemeMode.dark,
              ])
                DropdownMenuItem(
                  value: mode,
                  child: Text(Appearance.label(mode)),
                ),
            ],
            onChanged: (mode) {
              if (mode != null) setState(() => Appearance.choose(store, mode));
            },
          ),
        ),
      ),
    ];
  }

  List<Widget> _aboutSettings() {
    final theme = Theme.of(context);
    final tips = Tips(widget.services.store);
    return [
      if (widget.controller != null)
        _find(
          'discover',
          ListTile(
            leading: const Icon(Icons.explore_outlined),
            title: const Text('All features'),
            subtitle: const Text('Everything $appName can do, in one place'),
            trailing: const Icon(AppIcons.chevron),
            onTap: _openDiscover,
          ),
        ),
      _find(
        'whatsNew',
        ListTile(
          leading: const Icon(Icons.auto_awesome_outlined),
          title: const Text('What\'s new'),
          subtitle: const Text('In version $appVersion'),
          trailing: const Icon(AppIcons.chevron),
          onTap: () => WhatsNewDialog.show(context, widget.controller),
        ),
      ),
      _find(
        'tips',
        SwitchListTile(
          secondary: const Icon(Icons.lightbulb_outline),
          title: const Text('Show tips'),
          subtitle: const Text('A short tip when a feature could help'),
          value: tips.enabled,
          onChanged: (on) => setState(() => tips.enabled = on),
        ),
      ),
      _find(
        'privacy',
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Privacy'),
          subtitle: const SettingExplained(
            '$appName has no servers and collects nothing',
            more:
                'Mail is stored encrypted on this device and goes only to '
                'your own mail servers. Remote images and trackers are '
                'blocked. See what was kept from senders in the Privacy '
                'report.',
          ),
          trailing: const Icon(AppIcons.chevron),
          onTap: _openPrivacyReport,
        ),
      ),
      _find(
        'privacyPolicy',
        _WebPageTile(
          icon: Icons.policy_outlined,
          title: 'Privacy policy',
          page: privacyPolicyUrl,
        ),
      ),
      _find(
        'terms',
        _WebPageTile(
          icon: Icons.description_outlined,
          title: 'Terms of service',
          page: termsOfServiceUrl,
        ),
      ),
      _find(
        'licences',
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Licences'),
          subtitle: Text(
            '$appName is free software under the Mozilla Public License 2.0.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          trailing: const Icon(AppIcons.chevron),
          onTap: () =>
              showLicensePage(context: context, applicationName: appName),
        ),
      ),
      const Divider(height: 24),
      ListTile(
        leading: const Icon(Icons.tune),
        title: const Text('Advanced'),
        subtitle: const Text(
          'Outside link and file checks, rules on your mail server',
        ),
        trailing: const Icon(AppIcons.chevron),
        onTap: _openAdvanced,
      ),
    ];
  }

  // ----------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _twoPane = constraints.maxWidth >= SettingsPage.twoPaneWidth;
      return _twoPane ? _sideBySide(context) : _groupList(context);
    },
  );

  /// Phones: the search, then the groups.
  Widget _groupList(BuildContext context) => PageScaffold(
    title: 'Settings',
    boundBody: true,
    body: ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: _SearchButton(onTap: _search),
        ),
        for (final s in SettingsCatalog.sections)
          ListTile(
            key: ValueKey('settings-group-${s.id}'),
            leading: Icon(s.icon),
            title: Text(s.title),
            subtitle: Text(s.description),
            trailing: const Icon(AppIcons.chevron),
            onTap: () => _openSection(s.id),
          ),
      ],
    ),
  );

  /// Wider screens: the groups at the left, every setting at the right.
  Widget _sideBySide(BuildContext context) => PageScaffold(
    title: 'Settings',
    maxWidth: 1080,
    boundBody: true,
    body: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 256,
          child: _Rail(current: _current, onSearch: _search, onSelect: _jump),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _scrolled,
            child: SingleChildScrollView(
              key: _content,
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, s) in SettingsCatalog.sections.indexed) ...[
                    KeyedSubtree(
                      key: _key('section:${s.id}'),
                      child: _Group(
                        s.title,
                        description: s.description,
                        first: i == 0,
                      ),
                    ),
                    ..._tiles(s.id),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A group's settings on a page of their own (phones).
final class _SectionPage extends StatefulWidget {
  const _SectionPage({required this.page, required this.section, this.reveal});

  final _SettingsPageState page;
  final SettingsSection section;

  /// The setting to scroll to.
  final String? reveal;

  @override
  State<_SectionPage> createState() => _SectionPageState();
}

final class _SectionPageState extends State<_SectionPage> {
  @override
  void initState() {
    super.initState();
    if (widget.reveal case final id?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = widget.page._anchors['page:$id']?.currentContext;
        if (target != null && target.mounted) {
          Scrollable.ensureVisible(target, alignment: 0.2);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PageScaffold(
      title: widget.section.title,
      boundBody: true,
      body: ListenableBuilder(
        listenable: widget.page._revision,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
                child: Text(
                  widget.section.description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ...widget.page._tiles(widget.section.id, onPage: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// Looks like a search field; opens the settings search.
final class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Search settings',
      excludeSemantics: true,
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          key: const ValueKey('settings-search'),
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(AppIcons.search, size: 20, color: colors.onSurfaceVariant),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Search settings',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant),
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

/// The groups, beside the settings (wider screens).
final class _Rail extends StatelessWidget {
  const _Rail({
    required this.current,
    required this.onSearch,
    required this.onSelect,
  });

  final String current;
  final VoidCallback onSearch;
  final void Function(String section) onSelect;

  static const _row = 44.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final children = [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: _SearchButton(onTap: onSearch),
      ),
      for (final s in SettingsCatalog.sections)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
          child: Material(
            color: s.id == current
                ? colors.secondaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(_row / 2),
            child: InkWell(
              key: ValueKey('settings-rail-${s.id}'),
              borderRadius: BorderRadius.circular(_row / 2),
              onTap: () => onSelect(s.id),
              child: SizedBox(
                height: _row,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(s.icon, size: 20, color: colors.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        s.shortTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: s.id == current
                              ? colors.onSecondaryContainer
                              : colors.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
    // A list only when it doesn't fit (a short window), so the page has
    // one scrolling part.
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxHeight >= 64 + children.length * (_row + 2)
          ? Column(children: children)
          : ListView(children: children),
    );
  }
}

/// The settings search: names, and other words for them.
final class _SettingsSearch extends StatefulWidget {
  const _SettingsSearch({required this.android, required this.canDiscover});

  final bool android;

  /// Offers "All features" when nothing matches.
  final bool canDiscover;

  /// Returned to open "All features".
  static const discover = '@discover';

  @override
  State<_SettingsSearch> createState() => _SettingsSearchState();
}

final class _SettingsSearchState extends State<_SettingsSearch> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final query = _text.text.trim();
    final found = SettingsCatalog.search(query, android: widget.android);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _text,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search settings',
              prefixIcon: Icon(AppIcons.search, size: 20),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (found.isNotEmpty) Navigator.pop(context, found.first.id);
            },
          ),
        ),
        Expanded(
          child: query.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Type what you are looking for, in your own words: '
                    '"dark mode", "PIN", "spam", "signature"…',
                    style: muted,
                  ),
                )
              : found.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('No setting matches "$query".', style: muted),
                      if (widget.canDiscover)
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(context, _SettingsSearch.discover),
                          child: const Text('See all features'),
                        ),
                    ],
                  ),
                )
              : ListView(
                  children: [
                    for (final e in found)
                      ListTile(
                        title: Text(e.title),
                        subtitle: Text(
                          e.advanced
                              ? 'Help & about › Advanced'
                              : SettingsCatalog.section(e.section).title,
                        ),
                        onTap: () => Navigator.pop(context, e.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A setting found by the search: tinted, so the eye lands on it.
final class SettingHighlight extends StatelessWidget {
  const SettingHighlight({super.key, required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A Material of its own, so the tile's ink still shows on it.
    return Material(
      type: on ? MaterialType.canvas : MaterialType.transparency,
      color: on ? colors.primaryContainer : null,
      shape: on
          ? Border(left: BorderSide(color: colors.primary, width: 3))
          : null,
      child: child,
    );
  }
}

/// Settings for people who want more: checks by outside services (with
/// their own API keys) and rules on the mail server. Kept off the main
/// Settings page so it stays simple.
final class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage({
    super.key,
    required this.services,
    this.highlight,
  });

  final AppServices services;

  /// The setting found by the Settings search, marked.
  final String? highlight;

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
          SettingHighlight(
            on: widget.highlight == 'safeBrowsing',
            child: SwitchListTile(
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
          ),
          SettingHighlight(
            on: widget.highlight == 'virusTotal',
            child: SwitchListTile(
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
          ),
          const _Group('Mail server'),
          SettingHighlight(
            on: widget.highlight == 'serverRules',
            child: SwitchListTile(
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
          SettingHighlight(
            on: widget.highlight == 'learning',
            child: SwitchListTile(
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

/// A heading that names a group of settings, and says what is in it.
final class _Group extends StatelessWidget {
  const _Group(this.text, {this.description, this.first = false});

  final String text;
  final String? description;

  /// The first group has no line above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!first) const Divider(height: 1, indent: 16, endIndent: 16),
        Semantics(
          header: true,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, first ? 8 : 20, 16, 6),
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
        if (description case final description?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// A setting's explanation: one short line, and the rest folded behind
/// "Learn more", so the page reads as a list of settings rather than a
/// wall of text.
final class SettingExplained extends StatefulWidget {
  const SettingExplained(this.summary, {super.key, this.more});

  final String summary;
  final String? more;

  @override
  State<SettingExplained> createState() => _ExplainedState();
}

final class _ExplainedState extends State<SettingExplained> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final more = widget.more;
    if (more == null) return Text(widget.summary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.summary),
        if (_open)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(more)),
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 0),
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            textStyle: Theme.of(context).textTheme.labelMedium,
          ),
          onPressed: () => setState(() => _open = !_open),
          child: Text(_open ? 'Show less' : 'Learn more'),
        ),
      ],
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
