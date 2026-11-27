// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/theme/app_icons.dart';
import '../state/mail_controller.dart';
import '../state/mail_location.dart';
import '../state/message_list_model.dart';

/// Above search results, when the device found little: for each account,
/// a way to search all of its mail on the server (search on the device
/// only sees the mail kept here), then where that stands.
final class ServerSearchLine extends StatelessWidget {
  const ServerSearchLine({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.list,
    builder: (context, _) {
      final list = controller.list;
      if (list.location is! SearchLocation ||
          (!list.offersServerSearch && list.serverSearches.isEmpty)) {
        return const SizedBox.shrink();
      }
      final rows = [
        for (final account in controller.services.store.accounts.all())
          if (list.serverSearches[account.id] case final state?)
            _state(context, account, state)
          else if (list.offersServerSearch)
            _offer(account),
      ];
      if (rows.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      );
    },
  );

  Widget _offer(Account account) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      icon: const Icon(AppIcons.searchServer, size: 18),
      onPressed: () => controller.searchOnServer(account.id),
      label: Text(
        'Search all of ${account.email} on the server',
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );

  Widget _state(BuildContext context, Account account, ServerSearchState s) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final again = TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => controller.searchOnServer(account.id),
      child: const Text('Try again'),
    );
    final (Widget? lead, String text, Widget? action) = switch (s.status) {
      ServerSearchStatus.searching => (
        const SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        'Searching ${account.email} on the server…',
        null,
      ),
      ServerSearchStatus.done => (
        null,
        switch (s.found) {
          0 => 'Nothing more on the server for ${account.email}.',
          1 => '1 more from the server for ${account.email}.',
          final n => '$n more from the server for ${account.email}.',
        },
        null,
      ),
      ServerSearchStatus.offline => (
        Icon(AppIcons.offline, size: 18, color: quiet?.color),
        'You\'re offline, so the server of ${account.email} can\'t be '
            'searched. These are the results on this device.',
        again,
      ),
      ServerSearchStatus.failed => (
        Icon(AppIcons.problem, size: 18, color: theme.colorScheme.error),
        'Couldn\'t search ${account.email} on the server.',
        again,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          ?lead,
          Text(text, style: quiet),
          ?action,
        ],
      ),
    );
  }
}
