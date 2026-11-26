// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/detail_scaffold.dart';
import '../../inbox/state/mail_controller.dart';
import '../../reader/ui/email_page.dart';
import 'accounts_page.dart' show AccountWords;

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
    await EmailPage.open(context, controller, message, title: 'Email');
  }

  /// Every message from the company, in the app's own search.
  void _searchAll(BuildContext context) {
    controller.search(account.company);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final a = account;
    const date = AccountWords.day;

    // Emails by year, newest first.
    final byYear = <int, List<AccountRecord>>{};
    for (final r in a.records) {
      byYear.putIfAbsent(r.email.at.toLocal().year, () => []).add(r);
    }
    final kinds = [
      for (final e in AccountEvidence.values)
        if (a.evidence[e] case final span?) (e, span),
    ];

    return DetailScaffold(
      title: a.name,
      header: DetailHeader(
        leading: Avatar(name: a.name, address: a.company, size: 44),
        title: a.name,
        subtitle: a.closed ? 'Closed · ${a.company}' : a.company,
        facts: [
          DetailFact(
            label: a.addresses.length == 1 ? 'Address' : 'Addresses',
            value: a.addresses.isEmpty ? 'Not known' : a.addresses.join('\n'),
          ),
          DetailFact(
            label: 'Signed up',
            value: a.signedUp == null
                ? 'No welcome email found (first email '
                      '${date(a.firstSeen)})'
                : date(a.signedUp!),
          ),
          DetailFact(
            label: 'Latest',
            value:
                '${date(a.lastActivity)}, '
                '${AccountWords.noun(a.records.first.evidence)}',
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(AppIcons.hide, size: 18),
          label: const Text('Not an account'),
        ),
      ],
      children: [
        DetailSection(
          children: [
            for (final (kind, span) in kinds)
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
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => _searchAll(context),
            icon: const Icon(AppIcons.search),
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
                const Icon(AppIcons.tip),
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
        for (final MapEntry(key: year, value: records) in byYear.entries)
          DetailSection(
            title: '$year',
            children: [
              for (final r in records)
                ListTile(
                  key: ValueKey('account-email-${r.email.messageId}'),
                  leading: Icon(AccountWords.icon(r.evidence)),
                  title: Text(
                    r.email.subject.isEmpty ? '(no subject)' : r.email.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${date(r.email.at)} · '
                    '${_capital(AccountWords.noun(r.evidence))}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(AppIcons.chevron),
                  onTap: () => _openEmail(context, r.email.messageId),
                ),
            ],
          ),
      ],
    );
  }

  static String _capital(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}
