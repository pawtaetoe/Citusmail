// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'citusmail_theme.dart';

/// What a list shows when there is nothing in it: a quiet icon, one line
/// saying so, and, where it helps, a hint and something to do about it.
final class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.hint,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;

  /// A second, muted line: what to do or why it is empty.
  final String? hint;

  /// A button under the hint (needs [onAction]).
  final String? action;
  final VoidCallback? onAction;

  /// The icon's opacity: muted, but still 3:1 against the pane behind it.
  static const iconAlpha = 0.7;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hint = this.hint;
    final action = this.action;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CitusSpace.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 48,
                color: colors.onSurfaceVariant.withValues(alpha: iconAlpha),
              ),
              const SizedBox(height: CitusSpace.m),
              Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(height: CitusSpace.xs),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null && onAction != null) ...[
                const SizedBox(height: CitusSpace.l),
                OutlinedButton(onPressed: onAction, child: Text(action)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
