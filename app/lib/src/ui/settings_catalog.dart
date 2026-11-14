// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'app_icons.dart';

/// A group of settings, named for what people want to do.
final class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    String? shortTitle,
  }) : shortTitle = shortTitle ?? title;

  final String id;
  final String title;

  /// In lists of groups, where [title] is too long to fit.
  final String shortTitle;

  /// One line: what is in it.
  final String description;
  final IconData icon;
}

/// One setting, as the search knows it: its name, and other words people
/// use for it ("dark mode", "push", "PIN").
final class SettingEntry {
  const SettingEntry(
    this.id,
    this.section,
    this.title, {
    this.words = const [],
    this.androidOnly = false,
    this.desktopOnly = false,
    this.advanced = false,
  });

  final String id;

  /// The [SettingsSection.id] it is in.
  final String section;
  final String title;
  final List<String> words;
  final bool androidOnly;
  final bool desktopOnly;

  /// On the Advanced page.
  final bool advanced;
}

/// The settings, in order, and the words that find them.
abstract final class SettingsCatalog {
  static const sections = <SettingsSection>[
    SettingsSection(
      id: 'notifications',
      title: 'Notifications & checking mail',
      shortTitle: 'Notifications',
      description: 'What you are told about, and how quickly mail arrives',
      icon: AppIcons.notifications,
    ),
    SettingsSection(
      id: 'inbox',
      title: 'Inbox & sorting',
      description: 'New senders, mail while you were away, codes',
      icon: AppIcons.inbox,
    ),
    SettingsSection(
      id: 'writing',
      title: 'Writing',
      description: 'Writing and sending emails',
      icon: AppIcons.compose,
    ),
    SettingsSection(
      id: 'accounts',
      title: 'Accounts',
      description: 'Your email addresses, and how much mail is kept',
      icon: AppIcons.account,
    ),
    SettingsSection(
      id: 'privacy',
      title: 'Privacy & security',
      description: 'App lock, images from the web, blocked senders',
      icon: AppIcons.privacy,
    ),
    SettingsSection(
      id: 'devices',
      title: 'Devices & sync',
      description: 'Your phone and computers, kept the same',
      icon: AppIcons.devices,
    ),
    SettingsSection(
      id: 'ai',
      title: 'AI assistant (your own key)',
      shortTitle: 'AI assistant',
      description: 'Optional summaries, with your own key',
      icon: AppIcons.assistant,
    ),
    SettingsSection(
      id: 'appearance',
      title: 'Appearance',
      description: 'Light or dark',
      icon: AppIcons.appearance,
    ),
    SettingsSection(
      id: 'about',
      title: 'Help & about',
      description: 'All features, tips, privacy, and more options',
      icon: AppIcons.help,
    ),
  ];

  static SettingsSection section(String id) =>
      sections.firstWhere((s) => s.id == id);

  static const entries = <SettingEntry>[
    // Notifications & checking mail.
    SettingEntry(
      'notifications',
      'notifications',
      'New mail notifications',
      words: ['notify', 'push', 'alerts', 'sound', 'banner', 'badge'],
    ),
    SettingEntry(
      'notifyServices',
      'notifications',
      'Also for Notifications',
      words: ['bank', 'services', 'github', 'automated'],
    ),
    SettingEntry(
      'previews',
      'notifications',
      'Show message previews',
      words: ['preview', 'lock screen', 'content', 'private'],
    ),
    SettingEntry(
      'reminders',
      'notifications',
      'Bill and trial reminders',
      words: ['bills', 'due', 'trial', 'renewal', 'appointment', 'return'],
    ),
    SettingEntry(
      'monthlyRenewals',
      'notifications',
      'Also remind me of monthly renewals',
      words: ['subscription', 'monthly', 'renew'],
    ),
    SettingEntry(
      'followUps',
      'notifications',
      'Follow-up reminders',
      words: ['follow up', 'no reply', 'waiting', 'nudge', 'remind'],
    ),
    SettingEntry(
      'instantMail',
      'notifications',
      'Instant mail',
      words: [
        'push',
        'instant',
        'real time',
        'live',
        'background',
        'battery',
        'sync',
        'fetch',
        'idle',
      ],
      androidOnly: true,
    ),
    SettingEntry(
      'backgroundChecks',
      'notifications',
      'Background checks',
      words: ['battery', 'background', 'fetch', 'interval', 'how often'],
      androidOnly: true,
    ),
    // Inbox & sorting.
    SettingEntry(
      'newSinceAway',
      'inbox',
      'New since you were away',
      words: ['away', 'catch up', 'while you were gone', 'back'],
    ),
    SettingEntry(
      'screener',
      'inbox',
      'Screen first-time senders',
      words: [
        'screener',
        'spam',
        'unknown senders',
        'new senders',
        'strangers',
        'filter',
      ],
    ),
    SettingEntry(
      'screenOutPlace',
      'inbox',
      'Screened-out mail goes to',
      words: ['screener', 'screen out', 'where'],
    ),
    SettingEntry(
      'screenedSenders',
      'inbox',
      'Screened senders',
      words: ['let in', 'allowed', 'screener', 'decisions'],
    ),
    SettingEntry(
      'autoRead',
      'inbox',
      'Read receipts and bookings automatically',
      words: [
        'download',
        'subscriptions',
        'deliveries',
        'trips',
        'bookings',
        'receipts',
      ],
    ),
    SettingEntry(
      'codeCleanup',
      'inbox',
      'Clean up old codes',
      words: [
        'verification',
        'codes',
        'otp',
        'one-time',
        '2fa',
        'login code',
        'delete',
      ],
    ),
    // Writing.
    SettingEntry(
      'signOffs',
      'writing',
      'Sign-offs',
      words: ['signature', 'sign-off', 'sign off', 'closing', 'regards'],
    ),
    SettingEntry(
      'writing',
      'writing',
      'Writing tools',
      words: ['compose', 'send later', 'schedule', 'read receipt', 'remind me'],
    ),
    // Accounts.
    SettingEntry(
      'accounts',
      'accounts',
      'Your accounts',
      words: [
        'email address',
        'login',
        'password',
        'sign in',
        'imap',
        'gmail',
        'outlook',
        'remove account',
      ],
    ),
    SettingEntry(
      'addAccount',
      'accounts',
      'Add account',
      words: ['new account', 'another address', 'sign in'],
    ),
    SettingEntry(
      'keepMail',
      'accounts',
      'Keep mail from',
      words: [
        'storage',
        'space',
        'history',
        'offline',
        'older mail',
        'how far back',
      ],
    ),
    // Privacy & security.
    SettingEntry(
      'appLock',
      'privacy',
      'App lock',
      words: ['pin', 'passcode', 'password', 'lock', 'security'],
    ),
    SettingEntry(
      'lockAfter',
      'privacy',
      'Lock after leaving the app',
      words: ['timeout', 'auto lock'],
    ),
    SettingEntry(
      'biometrics',
      'privacy',
      'Unlock with fingerprint or face',
      words: ['biometrics', 'fingerprint', 'face', 'touch id'],
    ),
    SettingEntry('changePin', 'privacy', 'Change PIN', words: ['pin']),
    SettingEntry(
      'images',
      'privacy',
      'Images',
      words: [
        'pictures',
        'remote images',
        'tracking',
        'trackers',
        'pixels',
        'load images',
      ],
    ),
    SettingEntry(
      'blockedSenders',
      'privacy',
      'Blocked senders',
      words: ['block', 'spam', 'unwanted', 'unblock', 'junk'],
    ),
    // Devices & sync.
    SettingEntry(
      'deviceSync',
      'devices',
      'Sync between devices',
      words: ['other devices', 'phone', 'computer', 'same everywhere'],
    ),
    SettingEntry(
      'pairing',
      'devices',
      'Send accounts to a computer',
      words: ['qr', 'code', 'phone', 'move accounts', 'transfer'],
      androidOnly: true,
    ),
    SettingEntry(
      'pairing',
      'devices',
      'Add accounts from your phone',
      words: ['qr', 'code', 'phone', 'move accounts', 'transfer'],
      desktopOnly: true,
    ),
    // AI assistant (your own key).
    SettingEntry(
      'aiAssistant',
      'ai',
      'AI assistant',
      words: [
        'ai',
        'assistant',
        'gpt',
        'chatgpt',
        'claude',
        'llama',
        'openai',
        'anthropic',
        'meta',
        'api key',
        'key',
        'ollama',
        'local model',
        'llm',
      ],
    ),
    SettingEntry(
      'ai-summaries',
      'ai',
      'Summaries',
      words: ['summarise', 'summarize', 'summary', 'ai', 'tl;dr', 'tldr'],
    ),
    SettingEntry(
      'ai-writing',
      'ai',
      'Writing help',
      words: [
        'write with ai',
        'writing',
        'draft',
        'reply',
        'rewrite',
        'shorter',
        'friendlier',
        'formal',
        'tone',
        'spelling',
        'grammar',
        'translate',
        'ai',
      ],
    ),
    // Appearance.
    SettingEntry(
      'theme',
      'appearance',
      'Theme',
      words: [
        'dark mode',
        'light mode',
        'night',
        'colours',
        'colors',
        'appearance',
      ],
    ),
    // Help & about.
    SettingEntry(
      'discover',
      'about',
      'All features',
      words: ['discover', 'what can it do', 'help', 'features'],
    ),
    SettingEntry(
      'whatsNew',
      'about',
      'What\'s new',
      words: ['update', 'release', 'version', 'changes', 'new'],
    ),
    SettingEntry(
      'tips',
      'about',
      'Show tips',
      words: ['hints', 'help', 'don\'t show tips', 'onboarding'],
    ),
    SettingEntry(
      'privacy',
      'about',
      'Privacy',
      words: ['data', 'collects', 'trackers', 'privacy report'],
    ),
    SettingEntry(
      'privacyPolicy',
      'about',
      'Privacy policy',
      words: ['policy', 'legal'],
    ),
    SettingEntry(
      'terms',
      'about',
      'Terms of service',
      words: ['terms', 'legal'],
    ),
    SettingEntry(
      'licences',
      'about',
      'Licences',
      words: ['license', 'open source', 'free software'],
    ),
    // Advanced (its own page).
    SettingEntry(
      'safeBrowsing',
      'about',
      'Check links with Google Safe Browsing',
      words: ['links', 'phishing', 'scam', 'malware', 'safe browsing'],
      advanced: true,
    ),
    SettingEntry(
      'virusTotal',
      'about',
      'Ask VirusTotal about flagged files and links',
      words: ['virus', 'malware', 'attachments', 'files'],
      advanced: true,
    ),
    SettingEntry(
      'serverRules',
      'about',
      'Rules on the mail server',
      words: ['sieve', 'server', 'filters', 'rules'],
      advanced: true,
    ),
    SettingEntry(
      'learning',
      'about',
      'Learn from my corrections',
      words: ['learning', 'corrections', 'not a subscription'],
      advanced: true,
    ),
  ];

  /// The settings on this kind of device.
  static List<SettingEntry> available({required bool android}) => [
    for (final e in entries)
      if (!(e.androidOnly && !android) && !(e.desktopOnly && android)) e,
  ];

  /// The settings matching [query], best first: every word of the query
  /// must start a word of the setting's name, section or other names.
  static List<SettingEntry> search(String query, {required bool android}) {
    final words = _words(query);
    if (words.isEmpty) return const [];
    final scored = <(SettingEntry, int)>[];
    for (final e in available(android: android)) {
      final title = _words(e.title);
      final all = [
        ...title,
        ..._words(section(e.section).title),
        for (final w in e.words) ..._words(w),
      ];
      // Phrases count too ("dark mode", "lock screen").
      final phrase = e.words.any(
        (w) => w.toLowerCase().startsWith(query.trim().toLowerCase()),
      );
      if (!phrase && !words.every((q) => all.any((w) => w.startsWith(q)))) {
        continue;
      }
      final inTitle = words.every((q) => title.any((w) => w.startsWith(q)));
      scored.add((e, inTitle ? 0 : 1));
    }
    scored.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (e, _) in scored) e];
  }

  static List<String> _words(String text) => [
    for (final w in text.toLowerCase().split(RegExp(r"[^a-z0-9']+")))
      if (w.isNotEmpty) w,
  ];
}
