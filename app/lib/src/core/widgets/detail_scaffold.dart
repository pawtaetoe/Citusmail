// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// The page of one thing found in the mail (a delivery, a subscription,
/// a booking, an appointment, an online account): [title] in the app
/// bar, then a [header] card, the page's own [children] (its emails, say)
/// and, last, [actions] such as "Not a booking", in a centred column.
final class DetailScaffold extends StatelessWidget {
  const DetailScaffold({
    super.key,
    required this.title,
    required this.header,
    this.children = const [],
    this.actions = const [],
  });

  /// The width of the column.
  static const width = 760.0;

  final String title;
  final DetailHeader header;
  final List<Widget> children;

  /// Buttons at the end; a choice made with one pops the page with it.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: width),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              header,
              ...children,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 4, children: actions),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// The card at the top of a [DetailScaffold]: a picture ([leading]), the
/// [title] and a line under it, a few [notes], then the [facts] and what
/// follows them ([footer]: buttons, small print).
final class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.titleColor,
    this.subtitleColor,
    this.struck = false,
    this.notes = const [],
    this.facts = const [],
    this.footer = const [],
  });

  final Widget leading;
  final String title;
  final String subtitle;

  /// Instead of the usual colours (a problem, a cancellation).
  final Color? titleColor;
  final Color? subtitleColor;

  /// The title crossed out (a cancelled booking).
  final bool struck;

  /// Sentences under the title ("It was moved.").
  final List<String> notes;

  /// [DetailFact]s, under a line.
  final List<Widget> facts;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: titleColor,
                          decoration: struck
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: subtitleColor ?? colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            for (final note in notes) ...[
              const SizedBox(height: 12),
              Text(note, style: muted),
            ],
            const Divider(height: 28),
            ...facts,
            ...footer,
          ],
        ),
      ),
    );
  }
}

/// One line of a [DetailHeader]'s facts: a [label] and its [value], with
/// an optional button ([trailing]) and tap.
final class DetailFact extends StatelessWidget {
  const DetailFact({
    super.key,
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
    this.labelWidth = 84,
    this.hideEmpty = false,
  });

  /// For long labels ("Booked with"), on pages whose values may be empty:
  /// an empty one shows nothing.
  const DetailFact.wide({
    super.key,
    required this.label,
    required this.value,
    this.trailing,
    this.onTap,
  }) : labelWidth = 96,
       hideEmpty = true;

  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Wider for pages with long labels ("Booked with").
  final double labelWidth;

  /// Nothing shows for an empty [value].
  final bool hideEmpty;

  @override
  Widget build(BuildContext context) {
    if (hideEmpty && value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: trailing == null
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: onTap == null
                ? Text(value, style: theme.textTheme.bodyMedium)
                : GestureDetector(
                    onTap: onTap,
                    child: Text(value, style: theme.textTheme.bodyMedium),
                  ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A titled list on a [DetailScaffold] ("Emails", a year): [title], then
/// [children] in one card, a line between each.
final class DetailSection extends StatelessWidget {
  const DetailSection({super.key, this.title, required this.children});

  /// None for a card right under the header.
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title case final title?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) const Divider(height: 1, indent: 56),
                child,
              ],
            ],
          ),
        ),
      ],
    );
  }
}
