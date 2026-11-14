// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';
import 'features.dart';

/// The app's version, as in app/pubspec.yaml (a test checks they agree).
const appVersion = '0.5.13';

/// What a version brought that people can see, newest first: feature ids
/// from [Features]. Only features that shipped.
const releaseNotes = <({String version, List<String> features})>[
  (version: '0.5.12', features: ['deviceSync']),
  (version: '0.5.11', features: ['signOffs']),
  (version: '0.5.10', features: ['pairing']),
  // The 0.5 highlights, for the first start after updating to a version
  // with "What's new".
  (
    version: '0.5.0',
    features: [
      'appointments',
      'screener',
      'snooze',
      'sendLater',
      'followUps',
      'readReceipt',
      'newSinceAway',
      'trips',
    ],
  ),
];

/// "What's new": once per version, after an update (not on a fresh
/// install), until dismissed or a feature is opened.
final class WhatsNew {
  WhatsNew(this._store);

  final MailStore _store;

  static const seenKey = 'whatsNew.seen';

  /// The newest version whose notes were seen (null: never).
  String? get seenVersion => _store.settings.read(seenKey);

  /// The features new since the last version seen.
  List<Feature> get pending {
    final seen = seenVersion;
    if (seen == appVersion) return const [];
    return [
      for (final r in releaseNotes)
        if (seen == null || _newer(r.version, seen))
          for (final id in r.features) ?Features.byId(id),
    ];
  }

  /// This version's features (Settings, "What's new").
  static List<Feature> get current => [
    for (final r in releaseNotes.take(1))
      for (final id in r.features) ?Features.byId(id),
  ];

  void markSeen() {
    if (seenVersion != appVersion) _store.settings.write(seenKey, appVersion);
  }

  static bool _newer(String a, String b) {
    List<int> parts(String v) => [
      for (final p in v.split('.')) int.tryParse(p) ?? 0,
    ];
    final x = parts(a), y = parts(b);
    for (var i = 0; i < 3; i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d > 0;
    }
    return false;
  }
}

/// A small card at the top of the inbox after an update: what is new,
/// each with "Show me". Closing it, or opening one, puts it away.
final class WhatsNewCard extends StatefulWidget {
  const WhatsNewCard({super.key, required this.controller});

  final MailController controller;

  @override
  State<WhatsNewCard> createState() => _WhatsNewCardState();
}

final class _WhatsNewCardState extends State<WhatsNewCard> {
  late final _whatsNew = WhatsNew(widget.controller.services.store);
  late List<Feature> _features = _whatsNew.pending;

  void _close() {
    _whatsNew.markSeen();
    setState(() => _features = const []);
  }

  @override
  Widget build(BuildContext context) {
    if (_features.isEmpty) return const SizedBox.shrink();
    return ValueListenableBuilder(
      valueListenable: widget.controller.location,
      builder: (context, location, _) {
        if (location is! InboxLocation) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final shown = _features.take(4).toList();
        final more = _features.length - shown.length;
        return Container(
          key: const ValueKey('whats-new'),
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 6),
          decoration: BoxDecoration(
            color: colors.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(CitusmailTheme.radius),
            border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(AppIcons.whatsNew, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'New in $appName',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close What\'s new',
                    icon: const Icon(AppIcons.close, size: 18),
                    onPressed: _close,
                  ),
                ],
              ),
              for (final f in shown)
                Row(
                  children: [
                    const SizedBox(width: 34),
                    Expanded(
                      child: Text(
                        f.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.onPrimaryContainer),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        _close();
                        f.open(context, widget.controller);
                      },
                      child: Text('Show me', semanticsLabel: 'Show ${f.title}'),
                    ),
                  ],
                ),
              if (more > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 34),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () => WhatsNewDialog.show(
                      context,
                      widget.controller,
                      features: _features,
                      onOpen: _close,
                    ),
                    child: Text('And $more more'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Every new feature, with "Show me" (from the card, and Settings).
final class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog({super.key, required this.features, this.onShow});

  final List<Feature> features;

  /// Opens a feature, after the dialog closed. Null: no "Show me"
  /// (Settings opened without the mail screen).
  final void Function(Feature feature)? onShow;

  static Future<void> show(
    BuildContext context,
    MailController? controller, {
    List<Feature>? features,
    VoidCallback? onOpen,
  }) => showDialog<void>(
    context: context,
    builder: (_) => WhatsNewDialog(
      features: features ?? WhatsNew.current,
      onShow: controller == null
          ? null
          : (f) {
              onOpen?.call();
              if (context.mounted) f.open(context, controller);
            },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final onShow = this.onShow;
    return AlertDialog(
      title: const Text('What\'s new'),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 460,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final f in features)
              ListTile(
                leading: Icon(f.icon),
                title: Text(f.title),
                subtitle: Text(f.sentence),
                trailing: onShow == null
                    ? null
                    : TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          onShow(f);
                        },
                        child: const Text('Show me'),
                      ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
