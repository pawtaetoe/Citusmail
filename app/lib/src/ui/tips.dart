// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/mail_controller.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';
import 'features.dart';
import 'snooze_sheet.dart';

/// A short tip, shown once, at the moment its feature could help.
final class Tip {
  const Tip({
    required this.id,
    required this.icon,
    required this.title,
    required this.text,
    this.action,
    this.onAction,
  });

  final String id;
  final IconData icon;
  final String title;
  final String text;

  /// A button that does it ("Snooze it", "Open Trips").
  final String? action;
  final void Function(BuildContext context, MailController controller)?
  onAction;
}

/// Which tips were shown, and whether to show any: each tip once, at
/// most one per session (a run of the app), never while turned off.
final class Tips {
  Tips(this._store);

  final MailStore _store;

  static const offKey = 'tips.off';
  static const seenKey = 'tips.seen';

  /// The tip shown in this run of the app, per store (a fresh store, as
  /// in tests, is a fresh run).
  static final _session = Expando<(String, Object?)>('tip this session');

  bool get enabled => _store.settings.read(offKey) != 'on';
  set enabled(bool on) => _store.settings.write(offKey, on ? 'off' : 'on');

  Set<String> get seen => {
    for (final id in (_store.settings.read(seenKey) ?? '').split(','))
      if (id.isNotEmpty) id,
  };

  /// Whether [tip] may show now, at [where] (the email it is about); if
  /// so it counts as shown. It shows again only at the same place.
  bool take(Tip tip, {Object? where}) {
    final shown = _session[_store];
    if (shown != null) return enabled && shown == (tip.id, where);
    if (!enabled || seen.contains(tip.id)) return false;
    _session[_store] = (tip.id, where);
    _store.settings.write(seenKey, {...seen, tip.id}.join(','));
    return true;
  }

  /// Whether [tip] could show now at [where], without counting it as
  /// shown: to skip work for a tip that can't.
  bool couldTake(Tip tip, {Object? where}) {
    final shown = _session[_store];
    if (shown != null) return enabled && shown == (tip.id, where);
    return enabled && !seen.contains(tip.id);
  }

  /// Whether the tip shown in this session was put away.
  bool dismissed(String id) => _store.settings.read('$seenKey.dismissed') == id;

  void dismiss(String id) => _store.settings.write('$seenKey.dismissed', id);

  static final unsubscribe = Tip(
    id: 'unsubscribe',
    icon: AppIcons.unsubscribe,
    title: 'Unsubscribe in one tap',
    text:
        'Don\'t want these any more? Unsubscribe, above, stops them. '
        'Subscriptions in the sidebar lists what you pay for.',
  );

  static final snooze = Tip(
    id: 'snooze',
    icon: AppIcons.snooze,
    title: 'Not now? Snooze it',
    text:
        'A long conversation can wait: snooze it and it comes back to the '
        'top of your inbox when you choose.',
    action: 'Snooze it',
    onAction: (context, c) {
      final open = c.selected;
      if (open != null && c.canSnooze(open)) {
        SnoozeSheet.show(context, c, [open]);
      }
    },
  );

  static final trips = Tip(
    id: 'trips',
    icon: AppIcons.trips,
    title: 'Your trips in one place',
    text:
        'Bookings like this one are put together into trips, with times '
        'and confirmation numbers.',
    action: 'Open Trips',
    onAction: (context, c) => Features.byId('trips')?.open(context, c),
  );

  static final screener = Tip(
    id: 'screener',
    icon: AppIcons.screener,
    title: 'Decide who reaches your inbox',
    text:
        'With the Screener on, people writing to you for the first time '
        'wait for your OK before their mail reaches your inbox.',
    action: 'Set up Screener',
    onAction: (context, c) => Features.byId('screener')?.open(context, c),
  );

  /// The tip for reading [message], if one could help. [firstTimeSender]
  /// says whether it comes from someone new while the Screener is off;
  /// it is asked last, only when no other tip applies.
  static Tip? forMessage(
    StoredMessage message, {
    required bool canUnsubscribe,
    bool Function()? firstTimeSender,
  }) {
    final subject = message.subject ?? '';
    if (canUnsubscribe) return unsubscribe;
    if (message.section != SmartSection.newsletters &&
        TripFinder.looksLikeBooking(subject)) {
      return trips;
    }
    // A conversation of four emails or more.
    if (message.references.length >= 3) return snooze;
    // Personal mail from someone new, while the Screener is off.
    if (message.section == SmartSection.general &&
        (firstTimeSender?.call() ?? false)) {
      return screener;
    }
    return null;
  }
}

/// A tip in the reader, above the email: dismissible, never in the way.
final class TipCard extends StatefulWidget {
  const TipCard({super.key, required this.tip, required this.controller});

  final Tip tip;
  final MailController controller;

  @override
  State<TipCard> createState() => _TipCardState();
}

final class _TipCardState extends State<TipCard> {
  Tips get _tips => Tips(widget.controller.services.store);

  @override
  Widget build(BuildContext context) {
    final tip = widget.tip;
    if (_tips.dismissed(tip.id)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    void close() => setState(() => _tips.dismiss(tip.id));
    return Semantics(
      container: true,
      label: 'Tip',
      child: Container(
        key: ValueKey('tip-${tip.id}'),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(CitusmailTheme.radius),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(tip.icon, size: 20, color: colors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Tip: ${tip.title}', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    tip.text,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      if (tip.action case final action?)
                        TextButton(
                          onPressed: () {
                            close();
                            tip.onAction?.call(context, widget.controller);
                          },
                          child: Text(action),
                        ),
                      TextButton(
                        onPressed: () {
                          close();
                          _tips.enabled = false;
                        },
                        child: const Text('Don\'t show tips'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close tip',
              icon: const Icon(AppIcons.close, size: 18),
              onPressed: close,
            ),
          ],
        ),
      ),
    );
  }
}
