// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'app_icons.dart';

/// The "?" next to a page's title: what it opens and what it is called.
typedef PageHelp = ({String tooltip, VoidCallback onPressed});

/// A page opened from the sidebar or Settings ("Deliveries", "Settings"):
/// its title sits at the top of the content column, lined up with what is
/// under it, instead of far away at the window's left edge. The app bar
/// above carries only Back (and [actions], when a page has them).
///
/// [body] is laid out under the title. It centres its own content in a
/// column of the same [maxWidth] so the two line up, or, with
/// [boundBody], the page does it.
final class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.help,
    this.actions = const [],
    this.maxWidth = width,
    this.appBar,
    this.bottomNavigationBar,
    this.boundBody = false,
  });

  /// The usual width of a page's content column.
  static const width = 760.0;

  final String title;
  final Widget body;
  final PageHelp? help;

  /// Extra buttons in the app bar, at its right.
  final List<Widget> actions;

  final double maxWidth;

  /// Replaces the plain app bar for a while (e.g. "3 selected").
  final PreferredSizeWidget? appBar;

  final Widget? bottomNavigationBar;

  /// Puts [body] in the content column, for a body that doesn't.
  final bool boundBody;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: appBar ?? AppBar(actions: actions),
      bottomNavigationBar: bottomNavigationBar,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          key: const ValueKey('page-title'),
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                    ),
                    if (help case final help?)
                      IconButton(
                        tooltip: help.tooltip,
                        icon: const Icon(AppIcons.help),
                        onPressed: help.onPressed,
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: boundBody
                ? Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: body,
                    ),
                  )
                : body,
          ),
        ],
      ),
    );
  }
}
