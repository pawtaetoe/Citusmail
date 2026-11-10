// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import 'features.dart';
import 'page_scaffold.dart';

/// Every feature in one place, each said in a sentence with an "Open"
/// button, grouped like the sidebar. From the sidebar's Tools and from
/// Settings, Help & about.
final class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key, required this.controller, this.isAndroid});

  final MailController controller;

  /// Overrides the platform (tests).
  final bool? isAndroid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final features = Features.available(android: isAndroid);
    return PageScaffold(
      title: 'All features',
      boundBody: true,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Everything $appName can do. It all works on this device; '
              'open one to try it.',
              style: TextStyle(color: muted),
            ),
          ),
          for (final group in FeatureGroup.values)
            if (features.any((f) => f.group == group)) ...[
              Semantics(
                header: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(
                    group.title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              for (final f in features)
                if (f.group == group)
                  ListTile(
                    key: ValueKey('feature-${f.id}'),
                    leading: Icon(f.icon),
                    title: Text(f.title),
                    subtitle: Text(f.sentence),
                    trailing: TextButton(
                      onPressed: () => f.open(context, controller),
                      child: Text('Open', semanticsLabel: 'Open ${f.title}'),
                    ),
                    onTap: () => f.open(context, controller),
                  ),
            ],
        ],
      ),
    );
  }
}
