// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../mail/send_later_times.dart';
import '../ui/app_icons.dart';
import '../ui/send_later_sheet.dart';
import 'writing_hints.dart';

/// A writing hint as a quiet line under the recipients: what it says,
/// its action when it has one, and a button that hides it.
final class WritingHintLine extends StatelessWidget {
  const WritingHintLine({
    super.key,
    required this.hint,
    required this.onClose,
    required this.onSendLater,
    required this.onUseAddress,
  });

  final WritingHint hint;
  final VoidCallback onClose;
  final ValueChanged<LocalTimeHint> onSendLater;
  final ValueChanged<NearMissHint> onUseAddress;

  /// "11:40 PM", as the user's clock shows times.
  static String clock(BuildContext context, DateTime wall) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay(hour: wall.hour, minute: wall.minute),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  /// "Tomorrow 8:00 AM their time", with "8:00 AM for Maya (2:00 AM for
  /// you)" below: the first choice in Send later.
  static SendLaterSuggestion suggestion(
    BuildContext context,
    LocalTimeHint hint,
  ) {
    final now = SendLaterTimes.clock();
    final at = hint.morning(now);
    final theirs = clock(context, at.toUtc().add(hint.offset));
    final day = hint.morningIsTomorrow(now) ? 'Tomorrow' : 'This morning';
    return SendLaterSuggestion(
      title: '$day $theirs their time',
      detail:
          '$theirs for ${HintRules.names(hint.names)} '
          '(${SendLaterSheet.describe(context, at)} for you)',
      at: at,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, text, action) = switch (hint) {
      final LocalTimeHint h => (
        AppIcons.tonight,
        'It\'s ${clock(context, h.theirClock(SendLaterTimes.clock()))} for '
            '${HintRules.names(h.names)}. Send later?',
        ('Send later', () => onSendLater(h)),
      ),
      final ReplyTimeHint h => (AppIcons.time, h.sentence, null),
      final NearMissHint h => (
        AppIcons.warning,
        'You haven\'t written to ${h.typed.address} before. '
            'Did you mean ${h.suggested.address}?',
        ('Use ${h.suggested.address}', () => onUseAddress(h)),
      ),
    };
    final muted = colors.onSurfaceVariant;
    return Padding(
      key: const ValueKey('writing-hint'),
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Icon(
                icon,
                size: 18,
                color: hint is NearMissHint ? colors.tertiary : muted,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
                if (action case (final label, final onPressed))
                  TextButton(
                    key: const ValueKey('writing-hint-action'),
                    onPressed: onPressed,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(label),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('writing-hint-close'),
            tooltip: 'Hide this hint',
            visualDensity: VisualDensity.compact,
            icon: Icon(AppIcons.close, size: 18, color: muted),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
