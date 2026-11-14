// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'accounts_page.dart';
import 'app_icons.dart';
import 'appointments_page.dart';
import 'attachments_page.dart';
import 'block_dialog.dart';
import 'deliveries_page.dart';
import 'image_senders_page.dart';
import 'privacy_report_page.dart';
import 'sender_cleanup_page.dart';
import 'settings_page.dart';
import 'sign_offs_page.dart';
import 'subscriptions_page.dart';
import 'trips_page.dart';

/// How the features are grouped on the "All features" page: like the
/// sidebar first, then by what people do.
enum FeatureGroup {
  found('Found in your mail'),
  tools('Tools'),
  inbox('Inbox'),
  writing('Writing'),
  privacy('Privacy & security'),
  devices('Notifications & devices');

  const FeatureGroup(this.title);

  final String title;
}

/// One thing the app can do, said plainly, and how to get to it. Used by
/// "All features", "What's new" and the tips, so a feature is described
/// once.
final class Feature {
  const Feature({
    required this.id,
    required this.group,
    required this.icon,
    required this.title,
    required this.sentence,
    required this.open,
    this.androidOnly = false,
  });

  /// Stable: "What's new" and the tips name features by it.
  final String id;
  final FeatureGroup group;
  final IconData icon;
  final String title;

  /// What it does, in one sentence.
  final String sentence;

  /// Shows the feature: its page, its place in the mail, or its setting.
  final void Function(BuildContext context, MailController controller) open;

  final bool androidOnly;
}

/// Every feature, in the order "All features" lists them.
abstract final class Features {
  static Feature? byId(String id) => all.where((f) => f.id == id).firstOrNull;

  /// The features on this kind of device.
  static List<Feature> available({bool? android}) => [
    for (final f in all)
      if (!f.androidOnly || (android ?? Platform.isAndroid)) f,
  ];

  static void _push(BuildContext context, WidgetBuilder page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: page));

  /// Back to the mail, showing [location].
  static void _goTo(
    BuildContext context,
    MailController controller,
    MailLocation location,
  ) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    controller.goTo(location);
  }

  static void _setting(
    BuildContext context,
    MailController controller,
    String id,
  ) => SettingsPage.open(context, controller: controller, show: id);

  static final all = <Feature>[
    Feature(
      id: 'subscriptions',
      group: FeatureGroup.found,
      icon: AppIcons.subscriptions,
      title: 'Subscriptions',
      sentence:
          'What you pay for, found in your receipts, with bills and '
          'renewals coming up.',
      open: (context, c) =>
          _push(context, (_) => SubscriptionsPage(controller: c)),
    ),
    Feature(
      id: 'deliveries',
      group: FeatureGroup.found,
      icon: AppIcons.deliveries,
      title: 'Deliveries',
      sentence: 'Parcels on their way, from your shipping emails.',
      open: (context, c) =>
          _push(context, (_) => DeliveriesPage(controller: c)),
    ),
    Feature(
      id: 'trips',
      group: FeatureGroup.found,
      icon: AppIcons.trips,
      title: 'Trips',
      sentence: 'Flights, hotels and bookings, put together into trips.',
      open: (context, c) => _push(context, (_) => TripsPage(controller: c)),
    ),
    Feature(
      id: 'appointments',
      group: FeatureGroup.found,
      icon: AppIcons.appointments,
      title: 'Appointments',
      sentence: 'Appointments and table bookings coming up, from your mail.',
      open: (context, c) =>
          _push(context, (_) => AppointmentsPage(controller: c)),
    ),
    Feature(
      id: 'onlineAccounts',
      group: FeatureGroup.found,
      icon: AppIcons.onlineAccounts,
      title: 'Online accounts',
      sentence: 'The websites and apps you signed up to, from their emails.',
      open: (context, c) => _push(context, (_) => AccountsPage(controller: c)),
    ),
    Feature(
      id: 'cleanUp',
      group: FeatureGroup.tools,
      icon: AppIcons.cleanUp,
      title: 'Clean up',
      sentence: 'See who fills your inbox and clear out their mail at once.',
      open: (context, c) =>
          _push(context, (_) => SenderCleanupPage(controller: c)),
    ),
    Feature(
      id: 'privacyReport',
      group: FeatureGroup.tools,
      icon: AppIcons.privacyReport,
      title: 'Privacy report',
      sentence: 'The trackers and images that were kept from senders.',
      open: (context, c) => _push(
        context,
        (_) => PrivacyReportPage(services: c.services, onShowMail: c.search),
      ),
    ),
    Feature(
      id: 'files',
      group: FeatureGroup.tools,
      icon: AppIcons.attachment,
      title: 'Files',
      sentence: 'Every attachment in your mail, with its own search.',
      open: (context, c) =>
          _push(context, (_) => AttachmentsPage(controller: c)),
    ),
    Feature(
      id: 'aiAssistant',
      group: FeatureGroup.tools,
      icon: AppIcons.assistant,
      title: 'AI assistant (your own key)',
      sentence:
          'Optional: with your own key for Claude, GPT, Gemini, Meta Muse or a model on '
          'your computer, summarise an email or a whole conversation.',
      open: (context, c) => _setting(context, c, 'aiAssistant'),
    ),
    Feature(
      id: 'aiTranslate',
      group: FeatureGroup.tools,
      icon: AppIcons.translate,
      title: 'Translate',
      sentence:
          'Read an email in another language in yours, with the AI '
          'assistant and your own key.',
      open: (context, c) => _setting(context, c, 'ai-translate'),
    ),
    Feature(
      id: 'screener',
      group: FeatureGroup.inbox,
      icon: AppIcons.screener,
      title: 'Screener',
      sentence:
          'People writing for the first time wait for your OK before '
          'reaching your inbox.',
      open: (context, c) => _setting(context, c, 'screener'),
    ),
    Feature(
      id: 'newSinceAway',
      group: FeatureGroup.inbox,
      icon: AppIcons.newSinceAway,
      title: 'New since you were away',
      sentence: 'Mail that came while you were away, together at the top.',
      open: (context, c) => _setting(context, c, 'newSinceAway'),
    ),
    Feature(
      id: 'snooze',
      group: FeatureGroup.inbox,
      icon: AppIcons.snooze,
      title: 'Snooze',
      sentence:
          'Not now? Snooze an email and it comes back to the top when '
          'you choose.',
      open: (context, c) => _goTo(context, c, const SnoozedLocation()),
    ),
    Feature(
      id: 'pins',
      group: FeatureGroup.inbox,
      icon: AppIcons.pins,
      title: 'Pins',
      sentence: 'Pin an email to keep it at hand in Pins.',
      open: (context, c) => _goTo(context, c, const PinsLocation()),
    ),
    Feature(
      id: 'unsubscribe',
      group: FeatureGroup.inbox,
      icon: AppIcons.unsubscribe,
      title: 'Unsubscribe in one tap',
      sentence:
          'Newsletters get an Unsubscribe button at the top; '
          '$appName does the rest.',
      open: (context, c) =>
          _goTo(context, c, const SectionLocation(SmartSection.newsletters)),
    ),
    Feature(
      id: 'aiTidy',
      group: FeatureGroup.inbox,
      icon: AppIcons.assistant,
      title: 'Ask AI to tidy',
      sentence:
          'With your own AI key: say what to archive, move, pin or snooze, '
          'and check the list before anything happens.',
      open: (context, c) => _setting(context, c, 'ai-actions'),
    ),
    Feature(
      id: 'codes',
      group: FeatureGroup.inbox,
      icon: AppIcons.codes,
      title: 'Verification codes',
      sentence:
          'Codes show in the list, ready to copy; old ones can tidy '
          'themselves away.',
      open: (context, c) => _setting(context, c, 'codeCleanup'),
    ),
    Feature(
      id: 'sendLater',
      group: FeatureGroup.writing,
      icon: AppIcons.sendLater,
      title: 'Send later',
      sentence: 'Write now, and pick when the email goes out.',
      open: (context, c) => c.compose(),
    ),
    Feature(
      id: 'followUps',
      group: FeatureGroup.writing,
      icon: AppIcons.reminder,
      title: 'Remind me if no reply',
      sentence:
          'When you send an email, ask to be reminded if nobody answers '
          'in time.',
      open: (context, c) => _goTo(context, c, const FollowUpsLocation()),
    ),
    Feature(
      id: 'readReceipt',
      group: FeatureGroup.writing,
      icon: AppIcons.receipt,
      title: 'Ask for a read receipt',
      sentence: 'Ask to be told when your email is read.',
      open: (context, c) => c.compose(),
    ),
    Feature(
      id: 'writeWithAi',
      group: FeatureGroup.writing,
      icon: AppIcons.writeWithAi,
      title: 'Write with AI',
      sentence:
          'Optional, with your own key: draft a reply, or make your text '
          'shorter, friendlier, more formal, corrected or translated.',
      open: (context, c) => _setting(context, c, 'ai-writing'),
    ),
    Feature(
      id: 'signOffs',
      group: FeatureGroup.writing,
      icon: AppIcons.signOff,
      title: 'Sign-offs',
      sentence:
          'Several endings for your emails, a default per account, and a '
          'quick switch while you write.',
      open: (context, c) =>
          _push(context, (_) => SignOffsPage(services: c.services)),
    ),
    Feature(
      id: 'aiQuickReplies',
      group: FeatureGroup.writing,
      icon: AppIcons.quickReply,
      title: 'Quick replies',
      sentence:
          'Up to three short replies to a personal email, to start from, '
          'with the AI assistant and your own key.',
      open: (context, c) => _setting(context, c, 'ai-quickReplies'),
    ),
    Feature(
      id: 'images',
      group: FeatureGroup.privacy,
      icon: AppIcons.image,
      title: 'Images and trackers blocked',
      sentence:
          'Pictures from the web wait until you load them; choose senders '
          'you trust.',
      open: (context, c) =>
          _push(context, (_) => ImageSendersPage(services: c.services)),
    ),
    Feature(
      id: 'block',
      group: FeatureGroup.privacy,
      icon: AppIcons.block,
      title: 'Block senders',
      sentence: 'Mail from someone you blocked goes straight to Junk.',
      open: (context, c) =>
          _push(context, (_) => BlockedSendersPage(services: c.services)),
    ),
    Feature(
      id: 'appLock',
      group: FeatureGroup.privacy,
      icon: AppIcons.lock,
      title: 'App lock',
      sentence: 'Ask for a PIN, or your fingerprint, to open the app.',
      open: (context, c) => _setting(context, c, 'appLock'),
    ),
    Feature(
      id: 'scamWarnings',
      group: FeatureGroup.privacy,
      icon: AppIcons.scam,
      title: 'Scam warnings',
      sentence:
          'Emails that pretend to be someone else, and risky links and '
          'files, are flagged.',
      open: (context, c) => _setting(context, c, 'safeBrowsing'),
    ),
    Feature(
      id: 'notifications',
      group: FeatureGroup.devices,
      icon: AppIcons.notifications,
      title: 'Notifications and reminders',
      sentence:
          'New mail, bills and trials ending, and replies you are '
          'waiting for.',
      open: (context, c) => _setting(context, c, 'notifications'),
    ),
    Feature(
      id: 'instantMail',
      group: FeatureGroup.devices,
      icon: AppIcons.instantMail,
      title: 'Instant mail',
      sentence: 'New mail at once, also while your phone sleeps.',
      open: (context, c) => _setting(context, c, 'instantMail'),
      androidOnly: true,
    ),
    Feature(
      id: 'pairing',
      group: FeatureGroup.devices,
      icon: AppIcons.pairing,
      title: 'Add accounts from your phone',
      sentence:
          'Scan a code with your phone to sign in on your computer, '
          'without typing passwords.',
      open: (context, c) => _setting(context, c, 'pairing'),
    ),
    Feature(
      id: 'deviceSync',
      group: FeatureGroup.devices,
      icon: AppIcons.devices,
      title: 'Sync between devices',
      sentence:
          'Blocked senders, Screener choices, snoozes, sign-offs and how '
          'your mail is handled, the same on all your devices.',
      open: (context, c) => _setting(context, c, 'deviceSync'),
    ),
  ];
}
