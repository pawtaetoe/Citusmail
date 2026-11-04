// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_trust/mail_trust.dart';

import '../app.dart' show appName;
import '../mail/privacy_report_model.dart';
import '../services/app_services.dart';
import 'avatar.dart';
import 'citusmail_theme.dart';
import 'mail_shell.dart';

/// What the app kept from senders lately, like a browser's "trackers
/// blocked": trackers, remote images, tracking tags on links, read
/// receipts and scam warnings, and the senders that track the most.
/// Counted on the device from the mail whose content is stored.
final class PrivacyReportPage extends StatefulWidget {
  const PrivacyReportPage({
    super.key,
    required this.services,
    this.onShowMail,
    this.now,
  });

  final AppServices services;

  /// Shows a sender's mail (a search for their address); null leaves the
  /// senders without a link.
  final void Function(String address)? onShowMail;

  /// Today (tests).
  final DateTime Function()? now;

  @override
  State<PrivacyReportPage> createState() => _PrivacyReportPageState();
}

final class _PrivacyReportPageState extends State<PrivacyReportPage> {
  late final PrivacyReportModel _model = PrivacyReportModel(
    widget.services,
    now: widget.now,
  );

  @override
  void initState() {
    super.initState();
    _model.load();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  void _showMail(String address) {
    final show = widget.onShowMail;
    if (show == null) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    show(address);
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < MailShell.mediumWidth;
    final periods = ListenableBuilder(
      listenable: _model,
      builder: (context, _) => SegmentedButton<PrivacyPeriod>(
        showSelectedIcon: false,
        segments: [
          for (final p in PrivacyPeriod.values)
            ButtonSegment(value: p, label: Text(p.label)),
        ],
        selected: {_model.period},
        onSelectionChanged: (s) => _model.select(s.single),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy report')),
      // Phone: the period switch within thumb reach.
      bottomNavigationBar: phone
          ? Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: periods,
                ),
              ),
            )
          : null,
      body: SafeArea(
        top: false,
        bottom: !phone,
        child: ListenableBuilder(
          listenable: _model,
          builder: (context, _) {
            if (_model.loading) return _Counting(progress: _model.progress);
            final report = _model.report;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    if (!phone)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: periods,
                        ),
                      ),
                    _Headline(report: report, period: _model.period),
                    if (report.messages > 0) ...[
                      _Stats(report: report),
                      if (report.topTrackers.isNotEmpty) ...[
                        const _SectionTitle('Senders that track you most'),
                        for (final s in report.topTrackers)
                          _SenderTile(
                            sender: s,
                            onTap: widget.onShowMail == null
                                ? null
                                : () => _showMail(s.address),
                          ),
                      ],
                    ],
                    _SmallPrint(
                      counted: report.messages,
                      received: _model.received,
                      period: _model.period,
                      capped: _model.capped,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// While the messages are read.
final class _Counting extends StatelessWidget {
  const _Counting({required this.progress});

  final ({int done, int total})? progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (p != null && p.total > 0) ...[
            const SizedBox(height: 16),
            Text('Counting… ${_number(p.done)} of ${_number(p.total)} emails'),
          ],
        ],
      ),
    );
  }
}

/// The headline: trackers blocked, the number people remember.
final class _Headline extends StatelessWidget {
  const _Headline({required this.report, required this.period});

  final PrivacyReport report;
  final PrivacyPeriod period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final empty = report.messages == 0;
    final title = empty
        ? 'Nothing to count yet'
        : '$appName blocked ${_number(report.trackers)} '
              '${report.trackers == 1 ? 'tracker' : 'trackers'} ${period.phrase}';
    final line = empty
        ? 'None of the emails you received ${period.phrase} are on this '
              'device yet. They are counted once you open them.'
        : 'In ${_number(report.messages)} '
              '${report.messages == 1 ? 'email' : 'emails'} on this device.';
    // The app's promise at work, so it gets the brand's colour (as the
    // reader's privacy notice).
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusLarge),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 32, color: colors.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  line,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Each protection as a big number with one plain line.
final class _Stats extends StatelessWidget {
  const _Stats({required this.report});

  final PrivacyReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final stats = [
      _Stat(
        icon: Icons.visibility_off_outlined,
        value: r.trackers,
        label: r.trackers == 1 ? 'Tracker blocked' : 'Trackers blocked',
        line:
            'Tracking pixels tell a sender when and where you opened their '
            'email. $appName never loads them.',
      ),
      _Stat(
        icon: Icons.hide_image_outlined,
        value: r.remoteImages,
        label: r.remoteImages == 1
            ? 'Remote image held back'
            : 'Remote images held back',
        line:
            'Pictures from the internet show the sender your IP address and '
            'that you opened their email. They wait until you load them.',
      ),
      _Stat(
        icon: Icons.link_off,
        value: r.trackingLinks,
        label: r.trackingLinks == 1
            ? 'Link with tracking tags'
            : 'Links with tracking tags',
        line:
            'Tags like utm_source tell a sender which email you clicked. '
            '$appName removes them before a link opens.',
      ),
      _Stat(
        icon: Icons.mark_email_read_outlined,
        value: r.readReceipts,
        label: r.readReceipts == 1
            ? 'Read receipt not sent'
            : 'Read receipts not sent',
        line:
            'These senders asked to be told when you read their email. '
            '$appName never tells them.',
      ),
      _Stat(
        icon: Icons.gpp_maybe_outlined,
        value: r.warned,
        label: r.warned == 1 ? 'Email warned about' : 'Emails warned about',
        line:
            'Signs of a scam, such as a sender imitating a company you know '
            'or a link that hides where it goes.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        // Phone: one column, each number beside its name. Wider: two
        // columns of equal-height cards.
        if (constraints.maxWidth < 520) {
          return Column(
            children: [
              for (final s in stats)
                Padding(
                  padding: const EdgeInsets.only(top: gap),
                  child: s.compact(),
                ),
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < stats.length; i += 2)
              Padding(
                padding: const EdgeInsets.only(top: gap),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: stats[i]),
                      const SizedBox(width: gap),
                      Expanded(
                        child: i + 1 < stats.length
                            ? stats[i + 1]
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

final class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.value,
    required this.label,
    required this.line,
    this.inline = false,
  });

  final IconData icon;
  final int value;
  final String label;
  final String line;

  /// The number beside its name rather than above it.
  final bool inline;

  _Stat compact() =>
      _Stat(icon: icon, value: value, label: label, line: line, inline: true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final number = Text(
      _number(value),
      style:
          (inline
                  ? theme.textTheme.headlineMedium
                  : theme.textTheme.displaySmall)
              ?.copyWith(
                fontWeight: FontWeight.w600,
                color: value == 0 ? colors.onSurfaceVariant : null,
              ),
    );
    final name = Text(label, style: theme.textTheme.titleMedium);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (inline) ...[
                  number,
                  const SizedBox(width: 12),
                  Expanded(child: name),
                ] else
                  Expanded(child: number),
                const SizedBox(width: 8),
                Icon(icon, color: colors.primary),
              ],
            ),
            if (!inline) ...[const SizedBox(height: 2), name],
            const SizedBox(height: 4),
            Text(
              line,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// A sender that tracks: trackers per email and in all; opens their mail.
final class _SenderTile extends StatelessWidget {
  const _SenderTile({required this.sender, required this.onTap});

  final SenderTracking sender;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = sender;
    final name = s.name ?? s.address;
    final per = s.perEmail;
    final perText = per == per.roundToDouble()
        ? per.round().toString()
        : per.toStringAsFixed(1);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Avatar(name: name, address: s.address),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$perText ${per == 1 ? 'tracker' : 'trackers'} per email · '
        '${_number(s.trackers)} in ${_number(s.emails)} '
        '${s.emails == 1 ? 'email' : 'emails'}',
      ),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// The promise, and what was counted.
final class _SmallPrint extends StatelessWidget {
  const _SmallPrint({
    required this.counted,
    required this.received,
    required this.period,
    required this.capped,
  });

  final int counted;
  final int received;
  final PrivacyPeriod period;
  final bool capped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Everything here is counted on this device. Nothing is sent '
                  'anywhere.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Counted from the ${_number(counted)} of ${_number(received)} '
            '${received == 1 ? 'email' : 'emails'} received ${period.phrase} '
            'whose content is on this device, mostly the ones you opened. '
            'Nothing is downloaded for this report.'
            '${capped ? ' Only the newest ${_number(PrivacyReportModel.maxMessages)} '
                      'emails are counted.' : ''}',
            style: muted,
          ),
        ],
      ),
    );
  }
}

/// 1234 as "1,234".
String _number(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
