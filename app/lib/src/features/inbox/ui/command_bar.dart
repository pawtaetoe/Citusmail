// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/text/mail_text.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/theme/citusmail_theme.dart';
import '../../ai/ui/ai_translate.dart';
import '../../discover/state/feature_id.dart';
import '../../discover/ui/discover_page.dart';
import '../../discover/ui/features.dart';
import '../../discover/ui/keyboard_shortcuts.dart';
import '../../organise/ui/block_dialog.dart';
import '../../organise/ui/move_dialog.dart';
import '../../organise/ui/screener_page.dart';
import '../../organise/ui/snooze_sheet.dart';
import '../../reader/state/summaries.dart';
import '../../settings/ui/settings_catalog.dart';
import '../../settings/ui/settings_page.dart';
import '../state/commands.dart';
import '../state/mail_controller.dart';
import '../state/mail_location.dart';

/// The groups of the command bar's results, in their usual order.
enum CommandGroup {
  recent('Recent'),
  actions('Actions'),
  goTo('Go to'),
  settings('Settings'),
  create('New'),
  emails('Emails');

  const CommandGroup(this.title);

  final String title;
}

/// One thing the command bar can do.
final class Command {
  const Command({
    required this.id,
    required this.group,
    required this.title,
    required this.icon,
    required this.run,
    this.subtitle,
    this.words = const [],
    this.shortcut,
    this.remember = true,
  });

  /// Stable, and the only thing kept of it in the recent commands.
  final String id;
  final CommandGroup group;
  final String title;

  /// A little more, after the title (where it is, what it acts on).
  final String? subtitle;
  final IconData icon;

  /// Other words people use for it.
  final List<String> words;

  /// Its keyboard shortcut, if it has one.
  final String? shortcut;

  /// Whether it may go in the recent commands (not emails or searches).
  final bool remember;
  final VoidCallback run;
}

/// Everything the command bar offers right now: the actions that apply
/// to the open email or the selection, places, settings, new things, and
/// a search of the mail.
final class CommandCatalog {
  CommandCatalog(
    this.context,
    this.controller, {
    this.onAddAccount,
    bool? android,
  }) : _android = android ?? Platform.isAndroid;

  /// Where the commands run: the navigator below the dialog.
  final BuildContext context;
  final MailController controller;
  final VoidCallback? onAddAccount;
  final bool _android;

  MailStore get _store => controller.services.store;

  late final List<Command> actions = _actions();
  late final List<Command> places = _places();
  late final List<Command> settings = _settings();
  late final List<Command> create = _create();

  List<Command> get all => [...actions, ...places, ...settings, ...create];

  Command? byId(String id) => all.where((c) => c.id == id).firstOrNull;

  // -------------------------------------------------------------- actions

  List<Command> _actions() {
    final c = controller;
    final targets = c.targets;
    if (targets.isEmpty) return const [];
    final reader = c.reader.value;
    final ready = reader is ReaderReady ? reader : null;
    final one = targets.length == 1 ? targets.single : null;
    final on = c.selecting
        ? (one != null
              ? 'On the selected email'
              : 'On ${targets.length} selected emails')
        : 'On the open email';
    Command action(
      String id,
      String title,
      IconData icon,
      VoidCallback run, {
      String? shortcut,
      List<String> words = const [],
      String? subtitle,
    }) => Command(
      id: 'action.$id',
      group: CommandGroup.actions,
      title: title,
      subtitle: subtitle ?? on,
      icon: icon,
      shortcut: shortcut,
      words: words,
      run: run,
    );

    final canArchive = targets.any((m) {
      final archive = c.archiveFor(m);
      return archive != null && archive.id != m.mailboxId;
    });
    final oneAccount = targets.map((m) => m.accountId).toSet().length == 1;
    final snoozedOne = one != null && c.snoozedUntil(one) != null;
    final pinned = targets.every((m) => m.flags.flagged);
    final read = targets.every((m) => m.flags.seen);
    final open = c.selected;
    final summaries = c.services.summaries;
    return [
      if (canArchive)
        action(
          'archive',
          'Archive',
          AppIcons.archive,
          () => c.archive(targets),
          shortcut: 'E',
          words: const ['done', 'file away'],
        ),
      if (!targets.every(c.deletesForever))
        action(
          'delete',
          'Delete',
          AppIcons.delete,
          () => c.delete(targets.where((m) => !c.deletesForever(m)).toList()),
          shortcut: '#',
          words: const ['trash', 'move to trash', 'remove', 'bin'],
        ),
      if (oneAccount)
        action(
          'move',
          'Move to…',
          AppIcons.move,
          () => unawaited(MoveDialog.show(context, c, targets)),
          shortcut: 'V',
          words: const ['folder', 'file', 'label'],
        ),
      if (targets.any(c.canSnooze))
        action(
          'snooze',
          snoozedOne ? 'Change snooze time…' : 'Snooze…',
          AppIcons.snooze,
          () => unawaited(SnoozeSheet.show(context, c, targets)),
          shortcut: 'B',
          words: const ['later', 'remind', 'postpone', 'snooze'],
        ),
      action(
        'pin',
        pinned ? 'Unpin' : 'Pin',
        pinned ? AppIcons.pinOn : AppIcons.pinOff,
        () => c.togglePin(targets),
        shortcut: 'S',
        words: const ['pin', 'unpin', 'star', 'flag', 'keep', 'important'],
      ),
      action(
        'read',
        read ? 'Mark as unread' : 'Mark as read',
        read ? AppIcons.markUnread : AppIcons.markRead,
        () => c.toggleRead(targets),
        shortcut: 'U',
        words: const ['read', 'unread', 'seen', 'new'],
      ),
      if (one != null && c.blockFor(one) == null && c.canBlock(one))
        action(
          'block',
          'Block sender',
          AppIcons.block,
          () => unawaited(BlockDialog.show(context, c, one)),
          words: const ['spam', 'junk', 'ban', 'stop'],
        ),
      if (ready != null && open != null) ...[
        action(
          'reply',
          'Reply',
          AppIcons.reply,
          () => c.reply(ready),
          shortcut: 'R',
          words: const ['answer', 'respond'],
          subtitle: 'To the open email',
        ),
        action(
          'replyAll',
          'Reply all',
          AppIcons.replyAll,
          () => c.replyAll(ready),
          shortcut: 'A',
          words: const ['everyone', 'answer all', 'respond'],
          subtitle: 'To the open email',
        ),
        action(
          'forward',
          'Forward',
          AppIcons.forward,
          () => c.forward(ready),
          shortcut: 'F',
          words: const ['send on', 'share', 'fwd'],
          subtitle: 'The open email',
        ),
        if (summaries.available)
          action(
            'summarise',
            'Summarise',
            AppIcons.summarise,
            () => summaries.ask(ready.message, SummaryScope.message),
            words: const ['summary', 'summarize', 'short', 'ai'],
            subtitle: 'The open email, with the AI assistant',
          ),
        if (AiTranslate.isOn(c))
          action(
            'translate',
            'Translate',
            AppIcons.translate,
            () => AiTranslate.run(context, c, ready),
            words: const ['language', 'translation', 'ai'],
            subtitle: 'The open email, with the AI assistant',
          ),
      ],
    ];
  }

  // --------------------------------------------------------------- places

  void _goTo(MailLocation location) => controller.goTo(location);

  void _push(WidgetBuilder page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: page));

  List<Command> _places() {
    final c = controller;
    Command place(
      String id,
      String title,
      IconData icon,
      VoidCallback run, {
      String? subtitle,
      List<String> words = const [],
      String? shortcut,
    }) => Command(
      id: 'go.$id',
      group: CommandGroup.goTo,
      title: title,
      subtitle: subtitle,
      icon: icon,
      words: words,
      shortcut: shortcut,
      run: run,
    );

    Command feature(
      FeatureId id, {
      String? as,
      String? title,
      String? subtitle,
      List<String> words = const [],
    }) {
      final f = Features.byId(id)!;
      return place(
        as ?? id.name,
        title ?? f.title,
        f.icon,
        () => f.open(context, c),
        subtitle: subtitle ?? f.group.title,
        words: [f.title, ...words],
      );
    }

    final accounts = _store.accounts.all();
    final several = accounts.length > 1;
    return [
      place(
        'inbox',
        'Inbox',
        AppIcons.inbox,
        () => _goTo(const InboxLocation()),
        words: const ['mail', 'home', 'smart inbox'],
        subtitle: several ? 'All accounts' : null,
      ),
      place(
        'pins',
        'Pins',
        AppIcons.pins,
        () => _goTo(const PinsLocation()),
        words: const ['pinned', 'starred', 'flagged', 'important'],
      ),
      place(
        'snoozed',
        'Snoozed',
        AppIcons.snoozed,
        () => _goTo(const SnoozedLocation()),
        words: const ['later', 'snooze'],
      ),
      place(
        'followUps',
        'Waiting for a reply',
        AppIcons.waiting,
        () => _goTo(const FollowUpsLocation()),
        words: const ['follow up', 'no reply', 'reminders'],
      ),
      place(
        'outbox',
        'Outbox',
        AppIcons.outbox,
        () => _goTo(const OutboxLocation()),
        words: const ['sending', 'unsent', 'queue', 'failed'],
      ),
      place(
        'screener',
        'Screener',
        AppIcons.screener,
        () => _push((_) => ScreenerPage(controller: c)),
        words: const ['new senders', 'first time', 'waiting'],
      ),
      for (final section in SmartSection.values)
        if (section != SmartSection.screener && section != SmartSection.snoozed)
          place(
            'section.${section.name}',
            MailText.section(section),
            MailText.sectionIcon(section),
            () => _goTo(SectionLocation(section)),
            subtitle: 'In the inbox',
            words: const ['section'],
          ),
      for (final account in accounts) ...[
        if (several)
          place(
            'account.${account.id}',
            account.email,
            AppIcons.account,
            () => _goTo(InboxLocation(accountId: account.id)),
            subtitle: 'Inbox of this account',
            words: const ['account', 'inbox'],
          ),
        for (final mailbox in _store.mailboxes.forAccount(account.id))
          if (!mailbox.isInbox && !mailbox.isAppData && mailbox.selectable)
            place(
              'folder.${mailbox.id}',
              MailText.folder(mailbox),
              MailText.folderIcon(mailbox),
              () => _goTo(FolderLocation(mailbox.id, account.id)),
              subtitle: several ? account.email : 'Folder',
              words: [
                'folder',
                if (several) account.email,
                if (mailbox.name != MailText.folder(mailbox)) mailbox.name,
              ],
            ),
      ],
      feature(
        FeatureId.subscriptions,
        words: const ['bills', 'renewals', 'paid'],
      ),
      feature(
        FeatureId.deliveries,
        words: const ['parcels', 'packages', 'shipping'],
      ),
      feature(
        FeatureId.deliveries,
        as: 'returns',
        title: 'Returns',
        subtitle: 'In Deliveries',
        words: const ['refunds', 'send back'],
      ),
      feature(FeatureId.trips, words: const ['flights', 'hotels', 'bookings']),
      feature(
        FeatureId.appointments,
        words: const ['bookings', 'tables', 'events'],
      ),
      feature(FeatureId.onlineAccounts, words: const ['sign ups', 'websites']),
      feature(
        FeatureId.files,
        title: 'Attachments',
        words: const ['files', 'documents', 'photos'],
      ),
      feature(FeatureId.cleanUp, words: const ['senders', 'tidy']),
      feature(FeatureId.privacyReport, words: const ['trackers', 'images']),
      place(
        'settings',
        'Settings',
        AppIcons.settings,
        () => unawaited(SettingsPage.open(context, controller: c)),
        words: const ['preferences', 'options'],
      ),
      place(
        'features',
        'All features',
        AppIcons.allFeatures,
        () => _push((_) => DiscoverPage(controller: c)),
        words: const ['discover', 'help', 'what can it do'],
      ),
      place(
        'shortcuts',
        'Keyboard shortcuts',
        AppIcons.keyboard,
        () => unawaited(MailKeyboardShortcuts.showShortcuts(context)),
        shortcut: '?',
        words: const ['keys', 'help'],
      ),
    ];
  }

  // ------------------------------------------------------------- settings

  List<Command> _settings() => [
    for (final e in SettingsCatalog.available(android: _android))
      if (e.id != CommandBar.settingId)
        Command(
          id: 'setting.${e.id}',
          group: CommandGroup.settings,
          title: e.title,
          subtitle: SettingsCatalog.section(e.section).shortTitle,
          icon: SettingsCatalog.section(e.section).icon,
          words: [
            ...e.words,
            SettingsCatalog.section(e.section).title,
            'setting',
          ],
          run: () => unawaited(
            SettingsPage.open(context, controller: controller, show: e.id),
          ),
        ),
  ];

  // ------------------------------------------------------------------ new

  List<Command> _create() => [
    Command(
      id: 'new.message',
      group: CommandGroup.create,
      title: 'New message',
      icon: AppIcons.compose,
      shortcut: 'C',
      words: const ['compose', 'write', 'email', 'mail', 'send'],
      run: controller.compose,
    ),
    if (onAddAccount case final add?)
      Command(
        id: 'new.account',
        group: CommandGroup.create,
        title: 'Add account',
        icon: AppIcons.addAccount,
        words: const ['email address', 'sign in', 'log in', 'connect'],
        run: add,
      ),
  ];

  // --------------------------------------------------------------- emails

  /// How many emails the search shows.
  static const emailCount = 5;

  /// The emails matching [text] (the same search as the search field),
  /// and a search of all mail as the last row.
  List<Command> emails(String text) {
    final query = text.trim();
    if (query.isEmpty) return const [];
    return [
      for (final m in _store.messages.search(query, limit: emailCount))
        Command(
          id: 'email.${m.id}',
          group: CommandGroup.emails,
          title: MailText.subject(m),
          subtitle:
              '${MailText.sender(m)} · '
              '${MailText.listDate(context, m.receivedAt)}',
          icon: m.flags.seen ? AppIcons.mail : AppIcons.markUnread,
          remember: false,
          run: () => unawaited(controller.open(m)),
        ),
      Command(
        id: 'search',
        group: CommandGroup.emails,
        title: 'Search all mail for “$query”',
        icon: AppIcons.search,
        remember: false,
        run: () => controller.search(query),
      ),
    ];
  }
}

/// The results for what was typed, in groups.
final class CommandResults {
  const CommandResults(this.groups);

  final List<(CommandGroup, List<Command>)> groups;

  List<Command> get rows => [for (final (_, list) in groups) ...list];

  /// Most rows shown per group while typing.
  static const perGroup = 6;

  /// With nothing typed: recent commands, then what applies here, the
  /// main places, and new things. Otherwise the best matches, the group
  /// with the best match first, and emails last.
  static CommandResults of(
    CommandCatalog catalog,
    String query, {
    List<String> recent = const [],
  }) {
    if (query.trim().isEmpty) {
      final used = [for (final id in recent) ?catalog.byId(id)]
          .take(CommandHistory.size)
          .toList();
      final usedIds = {for (final c in used) c.id};
      List<Command> fresh(Iterable<Command> list) => [
        for (final c in list)
          if (!usedIds.contains(c.id)) c,
      ];
      return CommandResults([
        if (used.isNotEmpty) (CommandGroup.recent, used),
        if (fresh(catalog.actions) case final a when a.isNotEmpty)
          (CommandGroup.actions, a),
        if (fresh(catalog.places.take(5)) case final p when p.isNotEmpty)
          (CommandGroup.goTo, p),
        if (fresh(catalog.create) case final n when n.isNotEmpty)
          (CommandGroup.create, n),
      ]);
    }
    final scored = <(CommandGroup, List<Command>, double)>[];
    for (final (group, list) in [
      // On a tie, doing it comes before its setting.
      (CommandGroup.actions, catalog.actions),
      (CommandGroup.goTo, catalog.places),
      (CommandGroup.create, catalog.create),
      (CommandGroup.settings, catalog.settings),
    ]) {
      final found = <(Command, double)>[];
      for (final c in list) {
        final s = CommandMatch.score(query, c.title, words: c.words);
        if (s != null) found.add((c, s));
      }
      if (found.isEmpty) continue;
      // Stable: equal scores keep the catalog's order.
      final ranked = [for (final (i, f) in found.indexed) (f.$1, f.$2, i)]
        ..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$3 - b.$3);
      scored.add((
        group,
        [for (final r in ranked.take(perGroup)) r.$1],
        ranked.first.$2,
      ));
    }
    final order = [for (final (i, s) in scored.indexed) (s, i)]
      ..sort(
        (a, b) => b.$1.$3 != a.$1.$3 ? b.$1.$3.compareTo(a.$1.$3) : a.$2 - b.$2,
      );
    return CommandResults([
      for (final ((group, list, _), _) in order) (group, list),
      (CommandGroup.emails, catalog.emails(query)),
    ]);
  }
}

/// Ctrl+K (Cmd+K on a Mac): one box that finds emails, folders, settings
/// and actions. On wide windows only; phones have their own ways.
abstract final class CommandBar {
  /// Narrower than this, the command bar doesn't open.
  static const minWidth = 720.0;

  /// Its entry in the settings search.
  static const settingId = 'commandBar';

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;

  /// The keys, as shown.
  static String get keys => _mac ? 'Cmd+K' : 'Ctrl+K';

  /// Whether [event] is Ctrl+K (Cmd+K on a Mac).
  static bool isShortcut(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.keyK) {
      return false;
    }
    final k = HardwareKeyboard.instance;
    if (k.isAltPressed || k.isShiftPressed) return false;
    return _mac
        ? k.isMetaPressed && !k.isControlPressed
        : k.isControlPressed && !k.isMetaPressed;
  }

  /// Whether the window is wide enough for it.
  static bool fits(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= minWidth;

  static final _addAccount = Expando<VoidCallback>('add account');

  /// What "Add account" does for [controller]'s mail screen.
  static void register(MailController controller, {VoidCallback? addAccount}) {
    _addAccount[controller] = addAccount;
  }

  /// Opens the command bar over [context]'s navigator. [explain]: say
  /// why when the window is too narrow (for a button, not for the keys).
  static Future<void> show(
    BuildContext context,
    MailController controller, {
    bool explain = false,
  }) async {
    if (!fits(context)) {
      if (explain) {
        controller.onNotice?.call('The command bar needs a wider window.');
      }
      return;
    }
    final host = Navigator.of(context).context;
    final catalog = CommandCatalog(
      host,
      controller,
      onAddAccount: _addAccount[controller],
    );
    final history = CommandHistory(controller.services.store);
    final chosen = await showDialog<Command>(
      context: host,
      builder: (_) => CommandBarDialog(catalog: catalog, history: history),
    );
    if (chosen == null) return;
    if (chosen.remember) history.used(chosen.id);
    chosen.run();
  }
}

/// The command bar itself: a field, and the results under it. The field
/// keeps the keyboard; the arrows move through the results.
final class CommandBarDialog extends StatefulWidget {
  const CommandBarDialog({
    super.key,
    required this.catalog,
    required this.history,
  });

  final CommandCatalog catalog;
  final CommandHistory history;

  static const width = 640.0;

  @override
  State<CommandBarDialog> createState() => _CommandBarDialogState();
}

final class _CommandBarDialogState extends State<CommandBarDialog> {
  final _text = TextEditingController();
  final _field = FocusNode(debugLabel: 'command bar');
  final _scroll = ScrollController();
  late CommandResults _results;
  late List<String> _recent;
  int _index = 0;
  final _rowKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _recent = widget.history.ids;
    _results = CommandResults.of(widget.catalog, '', recent: _recent);
  }

  @override
  void dispose() {
    _text.dispose();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<Command> get _rows => _results.rows;

  void _changed(String text) {
    setState(() {
      _results = CommandResults.of(widget.catalog, text, recent: _recent);
      _index = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _run([Command? command]) {
    final rows = _rows;
    if (command == null && rows.isEmpty) return;
    Navigator.of(context)
        .pop(command ?? rows[_index.clamp(0, rows.length - 1)]);
  }

  /// Moves the highlight to row [index] and tells screen readers.
  void _highlight(int index, {bool announce = true}) {
    final rows = _rows;
    if (rows.isEmpty) return;
    final i = index.clamp(0, rows.length - 1);
    final up = i < _index;
    setState(() => _index = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _rowKeys[rows[i].id]?.currentContext;
      if (row != null && row.mounted) {
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: up
              ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
              : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
    if (announce) {
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          _label(rows[i]),
          Directionality.of(context),
        ),
      );
    }
  }

  /// The first row of the next group (or, [back], of the one before).
  void _nextGroup({bool back = false}) {
    final starts = <int>[];
    var at = 0;
    for (final (_, list) in _results.groups) {
      if (list.isEmpty) continue;
      starts.add(at);
      at += list.length;
    }
    if (starts.isEmpty) return;
    final current = starts.lastIndexWhere((s) => s <= _index);
    final next = back
        ? (_index > starts[current] ? current : current - 1)
        : current + 1;
    _highlight(starts[next % starts.length]);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (CommandBar.isShortcut(event)) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _highlight(_index + 1);
      case LogicalKeyboardKey.arrowUp:
        _highlight(_index - 1);
      case LogicalKeyboardKey.pageDown:
        _highlight(_index + 5);
      case LogicalKeyboardKey.pageUp:
        _highlight(_index - 5);
      case LogicalKeyboardKey.tab:
        _nextGroup(back: shift);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (event is KeyDownEvent) _run();
      case LogicalKeyboardKey.escape:
        Navigator.of(context).pop();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// What a screen reader says for [c]: its name, group and shortcut.
  String _label(Command c) {
    final group = [
      for (final (group, list) in _results.groups)
        if (list.contains(c)) group,
    ].firstOrNull;
    return [
      c.title,
      ?c.subtitle,
      (group ?? c.group).title,
      if (c.shortcut case final key?) 'shortcut $key',
    ].join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final rows = _rows;
    var row = 0;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: EdgeInsets.fromLTRB(
        CitusSpace.l,
        (size.height * 0.12).clamp(CitusSpace.l, 96),
        CitusSpace.l,
        CitusSpace.xl,
      ),
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusCard),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: CommandBarDialog.width,
          maxHeight: 560,
        ),
        child: SizedBox(
          width: CommandBarDialog.width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _onKey,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    CitusSpace.l,
                    CitusSpace.xs,
                    CitusSpace.m,
                    CitusSpace.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.search, color: colors.onSurfaceVariant),
                      const SizedBox(width: CitusSpace.m),
                      Expanded(
                        child: Semantics(
                          label: 'Command bar',
                          child: TextField(
                            controller: _text,
                            focusNode: _field,
                            autofocus: true,
                            onChanged: _changed,
                            style: theme.textTheme.titleMedium,
                            textInputAction: TextInputAction.go,
                            decoration: CitusmailTheme.bareField(
                              hintText:
                                  'Find emails, folders, settings and actions',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: CitusSpace.s),
                      const ExcludeSemantics(child: _Key('Esc')),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: CitusSpace.xs),
                  child: Semantics(
                    container: true,
                    role: SemanticsRole.list,
                    label: rows.isEmpty
                        ? 'No results'
                        : '${rows.length} results',
                    explicitChildNodes: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (group, list) in _results.groups)
                          if (list.isNotEmpty) ...[
                            _Heading(group.title),
                            for (final c in list)
                              _Row(
                                key: _rowKeys.putIfAbsent(
                                  c.id,
                                  () => GlobalKey(debugLabel: c.id),
                                ),
                                command: c,
                                label: _label(c),
                                highlighted: row++ == _index,
                                onHover: () => _highlight(
                                  rows.indexOf(c),
                                  announce: false,
                                ),
                                onTap: () => _run(c),
                              ),
                          ],
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              const ExcludeSemantics(child: _Hints()),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group's name over its rows.
final class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CitusSpace.l + CitusSpace.xs,
          CitusSpace.m,
          CitusSpace.l,
          CitusSpace.xs,
        ),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// One result: its icon, name, where or what, and its shortcut.
final class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.command,
    required this.label,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
  });

  final Command command;
  final String label;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fore = highlighted ? colors.onSecondaryContainer : colors.onSurface;
    final muted = highlighted
        ? colors.onSecondaryContainer.withValues(alpha: 0.75)
        : colors.onSurfaceVariant;
    return Semantics(
      container: true,
      role: SemanticsRole.listItem,
      button: true,
      selected: highlighted,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: MouseRegion(
        onHover: (_) {
          if (!highlighted) onHover();
        },
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 40,
            margin: const EdgeInsets.symmetric(horizontal: CitusSpace.s),
            padding: const EdgeInsets.symmetric(horizontal: CitusSpace.m),
            decoration: BoxDecoration(
              color: highlighted ? colors.secondaryContainer : null,
              borderRadius: BorderRadius.circular(CitusmailTheme.radiusSmall),
            ),
            child: Row(
              children: [
                Icon(command.icon, size: 20, color: muted),
                const SizedBox(width: CitusSpace.m),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: command.title,
                          style: TextStyle(
                            color: fore,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (command.subtitle case final more?)
                          TextSpan(
                            text: '   $more',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (command.shortcut case final key?) ...[
                  const SizedBox(width: CitusSpace.s),
                  _Key(key),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A key, drawn as a small keycap.
final class _Key extends StatelessWidget {
  const _Key(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusBadge),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// How to use it, at the bottom.
final class _Hints extends StatelessWidget {
  const _Hints();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget hint(String key, String what) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Key(key),
        const SizedBox(width: CitusSpace.xs),
        Text(what, style: style),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CitusSpace.l,
        vertical: CitusSpace.s,
      ),
      child: Wrap(
        spacing: CitusSpace.l,
        runSpacing: CitusSpace.xs,
        children: [
          hint('↑ ↓', 'Move'),
          hint('Enter', 'Open'),
          hint('Tab', 'Next group'),
          hint('Esc', 'Close'),
        ],
      ),
    );
  }
}
