// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_lookup/mail_lookup.dart';

/// "Check with VirusTotal" in a warning dialog: asks only when tapped,
/// then says what VirusTotal knows.
class VirusTotalCheck extends StatefulWidget {
  const VirusTotalCheck({super.key, required this.lookup, required this.what});

  final Future<VirusTotalReport> Function() lookup;

  /// "file" or "link", for the wording.
  final String what;

  /// The result in words.
  static String describe(VirusTotalReport report, String what) {
    if (!report.known) {
      return 'VirusTotal hasn\'t seen this $what before. That doesn\'t make it safe.';
    }
    final engines = report.engines;
    if (report.flagged) {
      final count = report.malicious + report.suspicious;
      return '$count of $engines security vendors on VirusTotal flag this $what as '
          'dangerous.';
    }
    return 'None of $engines security vendors on VirusTotal flag this $what. '
        'Stay careful anyway.';
  }

  @override
  State<VirusTotalCheck> createState() => _VirusTotalCheckState();
}

class _VirusTotalCheckState extends State<VirusTotalCheck> {
  bool _busy = false;
  String? _result;
  bool _flagged = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    String result;
    var flagged = false;
    try {
      final report = await widget.lookup();
      result = VirusTotalCheck.describe(report, widget.what);
      flagged = report.flagged;
    } on VirusTotalException catch (e) {
      result = 'VirusTotal couldn\'t check it: ${e.message}.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
      _flagged = flagged;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_result case final result?) {
      return Text(
        result,
        style: TextStyle(
          color: _flagged ? colors.error : colors.onSurfaceVariant,
          fontWeight: _flagged ? FontWeight.w600 : null,
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: _busy
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : TextButton.icon(
              icon: const Icon(Icons.policy_outlined, size: 18),
              label: const Text('Check with VirusTotal'),
              onPressed: _check,
            ),
    );
  }
}
