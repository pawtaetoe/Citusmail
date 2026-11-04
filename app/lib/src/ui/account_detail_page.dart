// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'accounts_page.dart' show AccountWords;
import 'avatar.dart';
import 'reader_pane.dart';

/// One online account: the address it uses, what its mail showed and
/// when, and every account email, each opening right here. Pops with
/// `true` when the user says it is not an account (the list then offers
/// Undo).
final class AccountDetailPage extends StatelessWidget {
  const AccountDetailPage({
    super.key,
    required this.account,
    required this.controller,
    required this.messageById,
  });

  final OnlineAccount account;
  final MailController controller;
  final StoredMessage? Function(int id) messageById;

  Future<void> _openEmail(BuildContext context, int messageId) async {
    final message = messageById(messageId);
    if (message == null) return;
    await controller.open(message);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _EmailPage(controller: controller),
      ),
    );
    // Back in the list: the mail screen behind shows no message.
    controller.closeMessage();
  }

  /// Every message from the company, in the app's own search.
  void _searchAll(BuildContext context) {
    controller.search(account.company);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final a = account;
    const date = AccountWords.day;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );

    // Emails by year, newest first.
    final byYear = <int, List<AccountRecord>>{};
    for (final r in a.records) {
      byYear.putIfAbsent(r.email.at.toLocal().year, () => []).add(r);
    }
    final kinds = [
      for (final e in AccountEvidence.values)
        if (a.evidence[e] case final span?) (e, span),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(a.name)),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Avatar(name: a.name, address: a.company, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    a.name,
                                    style: theme.textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    a.closed
                                        ? 'Closed · ${a.company}'
                                        : a.company,
                                    style: muted,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 28),
                        _Fact(
                          label: a.addresses.length == 1
                              ? 'Address'
                              : 'Addresses',
                          value: a.addresses.isEmpty
                              ? 'Not known'
                              : a.addresses.join('\n'),
                        ),
                        _Fact(
                          label: 'Signed up',
                          value: a.signedUp == null
                              ? 'No welcome email found (first email '
                                    '${date(a.firstSeen)})'
                              : date(a.signedUp!),
                        ),
                        _Fact(
                          label: 'Latest',
                          value:
                              '${date(a.lastActivity)}, '
                              '${AccountWords.noun(a.records.first.evidence)}',
                        ),
                      ],
                    ),
                  ),
                ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final (i, (kind, span)) in kinds.indexed) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        ListTile(
                          dense: true,
                          leading: Icon(AccountWords.icon(kind)),
                          title: Text(AccountWords.kind(kind)),
                          subtitle: Text(
                            span.count == 1
                                ? AccountWords.month(span.first)
                                : '${AccountWords.month(span.first)} – '
                                      '${AccountWords.month(span.latest)} · '
                                      '${span.count} emails',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _searchAll(context),
                    icon: const Icon(Icons.search),
                    label: Text('Search all mail from ${a.name}'),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  color: colors.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.lightbulb_outline),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'No longer use it? To close it, sign in on the '
                            '${a.name} website or app and look for "Delete '
                            'account" or "Close account" in its settings. '
                            'Citusmail doesn\'t open their site for you: go '
                            'there yourself, so you know it is the real one.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                for (final MapEntry(key: year, value: records)
                    in byYear.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
                    child: Text(
                      '$year',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (final (i, r) in records.indexed) ...[
                          if (i > 0) const Divider(height: 1, indent: 56),
                          ListTile(
                            key: ValueKey('account-email-${r.email.messageId}'),
                            leading: Icon(AccountWords.icon(r.evidence)),
                            title: Text(
                              r.email.subject.isEmpty
                                  ? '(no subject)'
                                  : r.email.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${date(r.email.at)} · '
                              '${_capital(AccountWords.noun(r.evidence))}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _openEmail(context, r.email.messageId),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    label: const Text('Not an account'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _capital(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// An account email, read in place: Back returns to the account.
final class _EmailPage extends StatefulWidget {
  const _EmailPage({required this.controller});

  final MailController controller;

  @override
  State<_EmailPage> createState() => _EmailPageState();
}

final class _EmailPageState extends State<_EmailPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.reader.addListener(_closedElsewhere);
  }

  @override
  void dispose() {
    widget.controller.reader.removeListener(_closedElsewhere);
    super.dispose();
  }

  /// Archived, deleted or closed from its own actions: back to the list.
  void _closedElsewhere() {
    // Only while this page is on top: going back closes the message too.
    if (widget.controller.reader.value.message == null &&
        mounted &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Email')),
    body: SafeArea(
      top: false,
      child: ReaderPane(controller: widget.controller, toolbarAtBottom: true),
    ),
  );
}
