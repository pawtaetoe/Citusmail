// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';

import '../mail/accounts_model.dart';
import '../mail/mail_controller.dart';
import '../services/app_services.dart';
import 'account_detail_page.dart';
import 'avatar.dart';
import 'badge.dart';
import 'read_ahead.dart';

/// Online services the user has an account with, found in welcome,
/// sign-in, password and security mail on the device: useful after a
/// data breach, when changing address, or to close old accounts.
final class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, required this.controller, this.now});

  final MailController controller;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

enum _Sort { recent, name }

final class _AccountsPageState extends State<AccountsPage> with ReadsAhead {
  late final AccountsModel _model = AccountsModel(
    widget.controller.services,
    now: widget.now,
  );
  final _search = TextEditingController();
  _Sort _sort = _Sort.recent;
  String? _address;
  bool _quietOnly = false;
  bool _showHidden = false;

  @override
  AppServices get services => widget.controller.services;

  @override
  Future<void> reload() => _model.load();

  @override
  void initState() {
    super.initState();
    _model.load().then((_) => loadedWith(_model.toRead));
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _model.stopReading();
    _model.dispose();
    _search.dispose();
    super.dispose();
  }

  /// The account's own page; "Not an account" there comes back here,
  /// with Undo.
  Future<void> _select(OnlineAccount a) async {
    _model.opened(a);
    final notOne = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AccountDetailPage(
          account: a,
          controller: widget.controller,
          messageById: _model.message,
        ),
      ),
    );
    if (notOne == true && mounted) _hide(a);
  }

  void _hide(OnlineAccount a) {
    _model.hide(a.company);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('${a.name} won\'t be listed as an account'),
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _model.unhide(a.company),
          ),
        ),
      );
  }

  List<OnlineAccount> _shown() {
    final query = _search.text.trim().toLowerCase();
    final list = [
      for (final a in _model.accounts)
        if ((query.isEmpty ||
                a.name.toLowerCase().contains(query) ||
                a.company.contains(query) ||
                a.addresses.any((x) => x.contains(query))) &&
            (_address == null || a.addresses.contains(_address)) &&
            (!_quietOnly || _model.isQuiet(a)))
          a,
    ];
    if (_sort == _Sort.name) {
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Online accounts'),
      actions: [
        IconButton(
          tooltip: 'How is this found?',
          icon: const Icon(Icons.help_outline),
          onPressed: () => _HowDialog.show(context),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: _model,
        builder: (context, _) {
          if (_model.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = _model.accounts;
          final addresses = _model.addressesUsed;
          if (_address != null && !addresses.contains(_address)) {
            _address = null;
          }
          final shown = _shown();
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (all.isEmpty)
                    const _Empty()
                  else
                    _Header(
                      count: all.length,
                      quiet: all.where(_model.isQuiet).length,
                    ),
                  if (_model.reading case final r?)
                    _Reading(
                      done: r.done,
                      total: r.total,
                      onStop: _model.stopReading,
                    )
                  else if (_model.toRead.isNotEmpty && !readsAhead)
                    _ReadOffer(
                      count: _model.toRead.length,
                      onRead: _model.readEmails,
                    )
                  else if (_model.toRead.isNotEmpty && readingAhead)
                    ReadingQuietly(
                      'Reading ${_model.toRead.length} account email'
                      '${_model.toRead.length == 1 ? '' : 's'}…',
                    ),
                  if (all.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _search,
                      decoration: InputDecoration(
                        hintText: 'Search services or addresses',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.close),
                                onPressed: _search.clear,
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // One row that scrolls sideways: the list stays in view
                    // on a phone.
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        spacing: 8,
                        children: [
                          SegmentedButton<_Sort>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                value: _Sort.recent,
                                label: Text('Recent'),
                              ),
                              ButtonSegment(
                                value: _Sort.name,
                                label: Text('A–Z'),
                              ),
                            ],
                            selected: {_sort},
                            onSelectionChanged: (s) =>
                                setState(() => _sort = s.single),
                          ),
                          FilterChip(
                            label: const Text('Not heard from in 2+ years'),
                            selected: _quietOnly,
                            onSelected: (on) => setState(() => _quietOnly = on),
                          ),
                          if (addresses.length > 1)
                            for (final address in addresses)
                              FilterChip(
                                label: Text(address),
                                selected: _address == address,
                                onSelected: (on) => setState(
                                  () => _address = on ? address : null,
                                ),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No accounts match.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                    for (final a in shown)
                      _AccountTile(account: a, onSelect: () => _select(a)),
                  ],
                  if (_model.hiddenOnes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            setState(() => _showHidden = !_showHidden),
                        child: Text(
                          _showHidden
                              ? 'Hide the ones marked "not an account"'
                              : 'Show ${_model.hiddenOnes.length} marked "not an account"',
                        ),
                      ),
                    ),
                    if (_showHidden)
                      for (final a in _model.hiddenOnes)
                        ListTile(
                          leading: Avatar(name: a.name, address: a.company),
                          title: Text(a.name),
                          subtitle: Text(
                            _model.learned.contains(a.company)
                                ? 'Left out: like ones you said aren\'t '
                                      'accounts'
                                : a.company,
                          ),
                          trailing: TextButton(
                            onPressed: () => _model.unhide(a.company),
                            child: const Text('List again'),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// "N services have an account with your email", and why that helps.
final class _Header extends StatelessWidget {
  const _Header({required this.count, required this.quiet});

  final int count;
  final int quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              count == 1
                  ? '1 service has an account with your email'
                  : '$count services have an account with your email',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Found in welcome emails, sign-in codes, password resets and '
              'security alerts on this device. Handy after a data breach, '
              'when you change your email address, or to close accounts you '
              'no longer use.',
              style: muted,
            ),
            if (quiet > 0) ...[
              const SizedBox(height: 6),
              Text('$quiet not heard from in over two years.', style: muted),
            ],
          ],
        ),
      ),
    );
  }
}

/// One account: the service, the address it uses, when it started and
/// its latest email, and tags.
final class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account, required this.onSelect});

  final OnlineAccount account;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final a = account;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final tags = [
      if (a.has(AccountEvidence.securityAlert)) 'Security alerts',
      if (a.has(AccountEvidence.paid)) 'Paid',
      if (a.closed) 'Closed',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('account-${a.company}'),
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Opacity(
                opacity: a.closed ? 0.6 : 1,
                child: Avatar(name: a.name, address: a.company),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (a.addresses.isNotEmpty)
                      Text(
                        a.addresses.length == 1
                            ? a.addresses.first
                            : '${a.addresses.first} +${a.addresses.length - 1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    Text(AccountWords.summary(a), style: muted),
                    if (tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [for (final t in tags) AppBadge(t)],
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Offers to download account emails whose preview says too little.
final class _ReadOffer extends StatelessWidget {
  const _ReadOffer({required this.count, required this.onRead});

  final int count;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.mark_email_unread_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Some accounts may be missing. $count welcome or account '
                    'email${count == 1 ? '' : 's'} not on this device yet can '
                    'be downloaded from your mail server to check (they stay '
                    'unread).',
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onRead,
                child: const Text('Read emails'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _Reading extends StatelessWidget {
  const _Reading({
    required this.done,
    required this.total,
    required this.onStop,
  });

  final int done;
  final int total;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reading emails: $done of $total'),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: total == 0 ? null : done / total,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: onStop, child: const Text('Stop')),
        ],
      ),
    ),
  );
}

final class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        children: [
          Icon(
            Icons.badge_outlined,
            size: 40,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text('No accounts found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Services you have an account with show here once welcome '
            'emails, sign-in codes or security alerts from them are in your '
            'mail.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

final class _HowDialog extends StatelessWidget {
  const _HowDialog();

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, builder: (_) => const _HowDialog());

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('How is this found?'),
    content: const Text(
      'Citusmail looks at the mail on this device for welcome and "confirm '
      'your email" messages, sign-in codes, password resets, new sign-in '
      'alerts, account changes and receipts. Each company is listed once, '
      'with the address its mail was sent to.\n\n'
      'Mail from people, replies and forwards, newsletters and one-off shop '
      'receipts are left out. Older mail that is no longer on this device '
      'cannot be seen, so some accounts may be missing. Nothing is sent '
      'anywhere. If something listed is not an account, open it and choose '
      '"Not an account".',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('OK'),
      ),
    ],
  );
}

/// Accounts in words.
abstract final class AccountWords {
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// "Mar 10, 2021".
  static String day(DateTime d) {
    final local = d.toLocal();
    return '${_months[local.month - 1]} ${local.day}, ${local.year}';
  }

  /// "Mar 2021".
  static String month(DateTime d) {
    final local = d.toLocal();
    return '${_months[local.month - 1]} ${local.year}';
  }

  /// What one email was, as a noun: "sign-in code".
  static String noun(AccountEvidence e) => switch (e) {
    AccountEvidence.signedUp => 'welcome email',
    AccountEvidence.signInCode => 'sign-in code',
    AccountEvidence.passwordReset => 'password reset',
    AccountEvidence.securityAlert => 'security alert',
    AccountEvidence.accountChange => 'account change',
    AccountEvidence.notice => 'account email',
    AccountEvidence.paid => 'receipt',
    AccountEvidence.closed => 'closed',
  };

  /// A heading for one kind: "Sign-in codes".
  static String kind(AccountEvidence e) => switch (e) {
    AccountEvidence.signedUp => 'Signed up',
    AccountEvidence.signInCode => 'Sign-in codes',
    AccountEvidence.passwordReset => 'Password resets',
    AccountEvidence.securityAlert => 'Security alerts',
    AccountEvidence.accountChange => 'Account changes',
    AccountEvidence.notice => 'Account emails',
    AccountEvidence.paid => 'Paid',
    AccountEvidence.closed => 'Closed',
  };

  static IconData icon(AccountEvidence e) => switch (e) {
    AccountEvidence.signedUp => Icons.waving_hand_outlined,
    AccountEvidence.signInCode => Icons.pin_outlined,
    AccountEvidence.passwordReset => Icons.lock_reset,
    AccountEvidence.securityAlert => Icons.shield_outlined,
    AccountEvidence.accountChange => Icons.manage_accounts_outlined,
    AccountEvidence.notice => Icons.mail_outline,
    AccountEvidence.paid => Icons.receipt_long_outlined,
    AccountEvidence.closed => Icons.no_accounts_outlined,
  };

  /// "Signed up Mar 2021 · last sign-in code Oct 2026".
  static String summary(OnlineAccount a) {
    final latest = a.records.first;
    final start = a.signedUp == null
        ? 'First email ${month(a.firstSeen)}'
        : 'Signed up ${month(a.signedUp!)}';
    if (a.closed) {
      return '$start · closed '
          '${month(a.evidence[AccountEvidence.closed]!.latest)}';
    }
    if (a.records.length == 1) return start;
    return '$start · last ${noun(latest.evidence)} ${month(latest.email.at)}';
  }
}
