// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

// The pieces every "Found in your mail" page (subscriptions, deliveries,
// trips, appointments, online accounts) has the same way.

/// A small title over a part of the list ("Upcoming").
final class FoundSectionTitle extends StatelessWidget {
  const FoundSectionTitle(this.text, {super.key, this.top = 20});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(4, top, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// The offer to download the emails whose preview says too little:
/// [text] says what may be missing, [button] reads them.
final class ReadEmailsOffer extends StatelessWidget {
  const ReadEmailsOffer({
    super.key,
    required this.icon,
    required this.text,
    required this.button,
    required this.onRead,
  });

  final IconData icon;
  final String text;
  final String button;
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
                Icon(icon),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: onRead, child: Text(button)),
            ),
          ],
        ),
      ),
    );
  }
}

/// While those emails are read: "Reading receipts: 3 of 12", with Stop.
final class ReadingEmails extends StatelessWidget {
  const ReadingEmails({
    super.key,
    required this.what,
    required this.done,
    required this.total,
    required this.onStop,
  });

  /// "receipts", "booking emails".
  final String what;
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
                Text('Reading $what: $done of $total'),
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

/// One item left out of a found page: what it is ([about]), or that it
/// was left out because it looks like ones the user said are not one
/// ([learned]).
typedef LeftOutItem = ({
  Widget leading,
  String title,
  String about,
  bool learned,
  VoidCallback onListAgain,
});

/// The items the user said are not one ("Not a booking", with Undo), and
/// those left out like them, folded under "Show 3 marked "not a
/// booking"", each with "List again".
final class LeftOutList extends StatelessWidget {
  const LeftOutList({
    super.key,
    required this.marked,
    required this.plural,
    required this.open,
    required this.onToggle,
    required this.items,
    this.oneLine = true,
  });

  /// "not a booking".
  final String marked;

  /// "bookings".
  final String plural;

  /// Whether the items show.
  final bool open;
  final VoidCallback onToggle;
  final List<LeftOutItem> items;

  /// Each item's line under its title is cut to one line.
  final bool oneLine;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: onToggle,
          child: Text(
            open
                ? 'Hide the ones marked "$marked"'
                : 'Show ${items.length} marked "$marked"',
          ),
        ),
      ),
      if (open)
        for (final item in items)
          ListTile(
            leading: item.leading,
            title: Text(item.title),
            subtitle: Text(
              item.learned
                  ? 'Left out: like ones you said aren\'t $plural'
                  : item.about,
              maxLines: oneLine ? 1 : null,
              overflow: oneLine ? TextOverflow.ellipsis : null,
            ),
            trailing: TextButton(
              onPressed: item.onListAgain,
              child: const Text('List again'),
            ),
          ),
    ],
  );
}
