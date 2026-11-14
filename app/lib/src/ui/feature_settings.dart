// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../background/background_mail.dart';
import '../mail/mail_controller.dart';
import '../services/app_services.dart';
import 'app_icons.dart';
import 'screener_page.dart';
import 'settings_page.dart';

// A feature's options, where the feature is: the same switches as in
// Settings, so nobody has to go there to find them.

/// Wraps a setting's tile (Settings marks the one searched for).
typedef SettingWrap = Widget Function(String id, Widget tile);

Widget _plain(String id, Widget tile) => tile;

/// Turning Instant mail on or off, as Android allows it.
abstract final class InstantMail {
  /// Returns whether it is on afterwards.
  static Future<bool> turn(
    BuildContext context,
    AppServices services,
    bool on, {
    Future<bool> Function() batteryLimited = BackgroundMail.batteryLimited,
  }) async {
    services.settings.instantMail = on;
    try {
      await BackgroundMail.setInstant(on);
      if (on && await batteryLimited()) {
        await BackgroundMail.askToRunInBackground();
      }
      return on;
    } on Object {
      services.settings.instantMail = !on;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Android didn\'t allow instant mail right now.'),
          ),
        );
      }
      return !on;
    }
  }
}

/// The Screener's options: on or off, where screened-out mail goes, and
/// every decision. In Settings and on the Screener page.
final class ScreenerSettings extends StatefulWidget {
  const ScreenerSettings({
    super.key,
    required this.services,
    this.controller,
    this.wrap = _plain,
  });

  final AppServices services;
  final MailController? controller;
  final SettingWrap wrap;

  @override
  State<ScreenerSettings> createState() => _ScreenerSettingsState();
}

final class _ScreenerSettingsState extends State<ScreenerSettings> {
  @override
  Widget build(BuildContext context) {
    final screener = widget.services.store.screener;
    final decided = screener.all().length;
    final wrap = widget.wrap;
    void changed() {
      setState(() {});
      widget.controller?.refresh();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        wrap(
          'screener',
          SwitchListTile(
            secondary: const Icon(AppIcons.screener),
            title: const Text('Screen first-time senders'),
            subtitle: const SettingExplained(
              'New senders wait in the Screener until you let them in',
              more:
                  'The Screener is at the top of your inbox. Everyone you '
                  'already have mail from is let in. Codes and replies to you '
                  'always come straight in.',
            ),
            value: screener.enabled,
            onChanged: (on) {
              on ? screener.enable() : screener.disable();
              changed();
            },
          ),
        ),
        if (screener.enabled)
          wrap(
            'screenOutPlace',
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
          ),
        wrap(
          'screenedSenders',
          ListTile(
            leading: const Icon(AppIcons.screenedSenders),
            title: const Text('Screened senders'),
            subtitle: Text(
              decided == 0
                  ? 'Senders you let in or screened out'
                  : '$decided ${decided == 1 ? 'sender' : 'senders'} you let in or screened out',
            ),
            trailing: const Icon(AppIcons.chevron),
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
        ),
      ],
    );
  }
}

/// The Screener's options, from the Screener page.
abstract final class ScreenerOptions {
  static Future<void> show(BuildContext context, MailController controller) =>
      _showPanel(
        context,
        title: 'Screener options',
        children: [
          ScreenerSettings(
            services: controller.services,
            controller: controller,
          ),
        ],
      );
}

/// "Read receipts and bookings automatically", on the pages it fills
/// (Subscriptions, Deliveries, Trips, Appointments, Online accounts).
final class AutoReadSwitch extends StatefulWidget {
  const AutoReadSwitch({super.key, required this.services});

  final AppServices services;

  @override
  State<AutoReadSwitch> createState() => _AutoReadSwitchState();
}

final class _AutoReadSwitchState extends State<AutoReadSwitch> {
  @override
  Widget build(BuildContext context) {
    final settings = widget.services.settings;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Read receipts and bookings automatically'),
      subtitle: const Text(
        'So this page fills in by itself. They stay unread.',
      ),
      value: settings.autoRead,
      onChanged: (on) {
        setState(() => settings.autoRead = on);
        if (on) widget.services.autoRead.request();
      },
    );
  }
}

/// Notifications and how mail is checked, from the sync status in the
/// sidebar: the main switches, and the way to the rest.
final class CheckingMailSheet extends StatefulWidget {
  const CheckingMailSheet({
    super.key,
    required this.controller,
    this.isAndroid,
  });

  final MailController controller;

  /// Overrides the platform (tests).
  final bool? isAndroid;

  static Future<void> show(
    BuildContext context,
    MailController controller, {
    bool? isAndroid,
  }) => _showPanel(
    context,
    title: 'Notifications and checking mail',
    children: [CheckingMailSheet(controller: controller, isAndroid: isAndroid)],
  );

  @override
  State<CheckingMailSheet> createState() => _CheckingMailSheetState();
}

final class _CheckingMailSheetState extends State<CheckingMailSheet> {
  AppServices get _services => widget.controller.services;

  @override
  Widget build(BuildContext context) {
    final settings = _services.settings;
    final android = widget.isAndroid ?? Platform.isAndroid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          secondary: const Icon(AppIcons.notifications),
          title: const Text('New mail notifications'),
          subtitle: const Text('One for each new email'),
          value: settings.notifications,
          onChanged: (on) => setState(() => settings.notifications = on),
        ),
        if (android)
          SwitchListTile(
            secondary: const Icon(AppIcons.instantMail),
            title: const Text('Instant mail'),
            subtitle: Text(
              settings.instantMail
                  ? 'New mail at once, also while your phone sleeps'
                  : 'Off: checked about every 5 minutes',
            ),
            value: settings.instantMail,
            onChanged: (on) async {
              setState(() => settings.instantMail = on);
              await InstantMail.turn(context, _services, on);
              if (mounted) setState(() {});
            },
          ),
        ListTile(
          leading: const Icon(AppIcons.sync),
          title: const Text('Check for new mail now'),
          onTap: () {
            Navigator.pop(context);
            widget.controller.syncNow();
          },
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextButton(
              onPressed: () {
                Navigator.pop(context);
                SettingsPage.open(
                  context,
                  controller: widget.controller,
                  show: 'notifications',
                );
              },
              child: const Text('All notification settings'),
            ),
          ),
        ),
      ],
    );
  }
}

/// A sheet on phones, a dialog on wider screens.
Future<void> _showPanel(
  BuildContext context, {
  required String title,
  required List<Widget> children,
}) {
  final narrow = MediaQuery.sizeOf(context).width < 720;
  Widget body(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      ...children,
    ],
  );
  if (narrow) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) =>
          SafeArea(child: SingleChildScrollView(child: body(context))),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(child: body(context)),
      ),
    ),
  );
}
