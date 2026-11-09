// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import '../services/app_services.dart';
import 'app_icons.dart';
import 'avatar.dart';
import 'mail_shell.dart';
import 'mail_text.dart';
import 'page_scaffold.dart';
import 'subscription_detail_page.dart' show EmailPage;

/// What happens to screened-out mail, in words.
String screenOutText(ScreenOutPlace place) => switch (place) {
  ScreenOutPlace.newsletters => 'the Newsletters section',
  ScreenOutPlace.notifications => 'the Notifications section',
  ScreenOutPlace.archive => 'Archive',
};

/// The Screener: everyone writing for the first time, each with their
/// first email, and Let in / Screen out.
///
/// On wide screens each sender has their buttons. On phones one sender
/// is picked at a time (the first, or the one tapped) and the buttons sit
/// in a bar at the bottom, within reach of the thumb; after a decision
/// the next sender is picked, so a queue is cleared with one thumb.
final class ScreenerPage extends StatefulWidget {
  const ScreenerPage({super.key, required this.controller, this.accountId});

  final MailController controller;

  /// The inbox shown (null: every account).
  final int? accountId;

  @override
  State<ScreenerPage> createState() => _ScreenerPageState();
}

final class _ScreenerPageState extends State<ScreenerPage> {
  late List<WaitingSender> _waiting;
  String? _picked;

  MailController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
    _c.list.addListener(_changed);
  }

  @override
  void dispose() {
    _c.list.removeListener(_changed);
    super.dispose();
  }

  void _load() => _waiting = _c.waitingSenders(accountId: widget.accountId);

  /// Decisions, Undo and new mail all refresh the list.
  void _changed() {
    if (mounted) setState(_load);
  }

  WaitingSender? get _current =>
      _waiting.where((w) => w.address == _picked).firstOrNull ??
      _waiting.firstOrNull;

  Future<void> _read(WaitingSender sender) =>
      EmailPage.open(context, _c, sender.first, title: 'Screener');

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < MailShell.mediumWidth;
    final current = _current;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final place = _c.services.store.screener.outPlace;
    return PageScaffold(
      title: 'Screener',
      body: SafeArea(
        top: false,
        bottom: !phone,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    'These people are writing to you for the first time. '
                    'Let them in and their mail goes to your inbox. Screen '
                    'them out and it goes to ${screenOutText(place)}, '
                    'without notifications. Nothing is deleted, and you can '
                    'change your mind in Settings.',
                    style: TextStyle(color: muted),
                  ),
                ),
                if (_waiting.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No one is waiting. New senders appear here before '
                      'they reach your inbox.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted),
                    ),
                  ),
                for (final sender in _waiting)
                  _SenderCard(
                    sender: sender,
                    controller: _c,
                    picked: phone && sender == current,
                    showActions: !phone,
                    onTap: phone
                        ? () => setState(() => _picked = sender.address)
                        : () => _read(sender),
                    onRead: () => _read(sender),
                  ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: phone && current != null
          ? _PhoneBar(sender: current, controller: _c)
          : null,
    );
  }
}

/// One waiting sender: who, how many emails, and the first one.
final class _SenderCard extends StatelessWidget {
  const _SenderCard({
    required this.sender,
    required this.controller,
    required this.picked,
    required this.showActions,
    required this.onTap,
    required this.onRead,
  });

  final WaitingSender sender;
  final MailController controller;
  final bool picked;
  final bool showActions;
  final VoidCallback onTap;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final first = sender.first;
    final name = sender.name ?? sender.address;
    final count = sender.messages.length;
    final preview = first.snippet?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: picked
            ? BorderSide(color: colors.primary, width: 2)
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        selected: picked,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Avatar(name: name, address: sender.address, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                          if (sender.name != null)
                            Text(
                              sender.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          Text(
                            [
                              count == 1 ? '1 email' : '$count emails',
                              MailText.listDate(
                                context,
                                sender.latest.receivedAt,
                              ),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _MoreMenu(sender: sender, controller: controller),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        MailText.subject(first),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: first.flags.seen
                              ? FontWeight.w500
                              : FontWeight.w700,
                        ),
                      ),
                      if (preview != null && preview.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    TextButton(
                      onPressed: onRead,
                      child: Text(
                        count == 1 ? 'Read it' : 'Read the first email',
                      ),
                    ),
                    const Spacer(),
                    if (showActions) ...[
                      OutlinedButton(
                        onPressed: () => controller.screenOut(sender),
                        child: const Text('Screen out'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => controller.letIn(sender),
                        child: const Text('Let in'),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Everyone at …" choices, for senders from a company's own domain.
final class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.sender, required this.controller});

  final WaitingSender sender;
  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final domain = controller.screenerDomain(sender.address);
    if (domain == null) return const SizedBox(width: 8);
    return PopupMenuButton<bool>(
      tooltip: 'More choices',
      icon: const Icon(AppIcons.more),
      onSelected: (letIn) => letIn
          ? controller.letIn(sender, wholeDomain: true)
          : controller.screenOut(sender, wholeDomain: true),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: true,
          child: ListTile(
            leading: const Icon(Icons.domain_verification_outlined),
            title: Text('Let in everyone at $domain'),
          ),
        ),
        PopupMenuItem(
          value: false,
          child: ListTile(
            leading: const Icon(Icons.domain_disabled_outlined),
            title: Text('Screen out everyone at $domain'),
          ),
        ),
      ],
    );
  }
}

/// Phones: the picked sender's choices at the bottom of the screen.
final class _PhoneBar extends StatelessWidget {
  const _PhoneBar({required this.sender, required this.controller});

  final WaitingSender sender;
  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = sender.name ?? sender.address;
    return Material(
      color: colors.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: () => controller.screenOut(sender),
                      child: const Text('Screen out'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: () => controller.letIn(sender),
                      child: const Text('Let in'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings > Screened senders: every decision, to change or forget.
final class ScreenedSendersPage extends StatefulWidget {
  const ScreenedSendersPage({
    super.key,
    required this.services,
    this.controller,
  });

  final AppServices services;

  /// The mail screen, refreshed after a change.
  final MailController? controller;

  @override
  State<ScreenedSendersPage> createState() => _ScreenedSendersPageState();
}

enum _Change { letIn, screenOut, forget }

final class _ScreenedSendersPageState extends State<ScreenedSendersPage> {
  ScreenerRepository get _screener => widget.services.store.screener;

  void _change(ScreenedSender s, _Change change) {
    switch (change) {
      case _Change.letIn:
        _screener.decide(s.kind, s.value, ScreenerDecision.letIn);
      case _Change.screenOut:
        _screener.decide(s.kind, s.value, ScreenerDecision.screenOut);
      case _Change.forget:
        _screener.remove(s.id);
    }
    widget.controller?.refresh();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final all = _screener.all();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final letIn = [
      for (final s in all)
        if (s.decision == ScreenerDecision.letIn) s,
    ];
    final out = [
      for (final s in all)
        if (s.decision == ScreenerDecision.screenOut) s,
    ];
    Widget tile(ScreenedSender s) {
      final isIn = s.decision == ScreenerDecision.letIn;
      final domain = s.kind == ScreenerKind.domain;
      return ListTile(
        leading: Icon(
          domain
              ? (isIn
                    ? Icons.domain_verification_outlined
                    : Icons.domain_disabled_outlined)
              : (isIn ? AppIcons.screener : Icons.person_off_outlined),
        ),
        title: Text(domain ? 'Everyone at ${s.value}' : s.value),
        subtitle: Text(
          'Since ${MaterialLocalizations.of(context).formatMediumDate(s.since.toLocal())}',
        ),
        trailing: PopupMenuButton<_Change>(
          tooltip: 'Change',
          icon: const Icon(AppIcons.more),
          onSelected: (c) => _change(s, c),
          itemBuilder: (_) => [
            if (isIn)
              const PopupMenuItem(
                value: _Change.screenOut,
                child: Text('Screen out'),
              )
            else
              const PopupMenuItem(value: _Change.letIn, child: Text('Let in')),
            const PopupMenuItem(
              value: _Change.forget,
              child: Text('Ask again next time'),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Screened senders')),
      body: all.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No decisions yet. When someone writes to you for the first '
                  'time, let them in or screen them out in the Screener at '
                  'the top of your inbox.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
              ),
            )
          : ListView(
              children: [
                if (letIn.isNotEmpty) ...[
                  const _Heading('Let in'),
                  for (final s in letIn) tile(s),
                ],
                if (out.isNotEmpty) ...[
                  _Heading(
                    'Screened out: their mail goes to '
                    '${screenOutText(_screener.outPlace)}',
                  ),
                  for (final s in out) tile(s),
                ],
              ],
            ),
    );
  }
}

final class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}
