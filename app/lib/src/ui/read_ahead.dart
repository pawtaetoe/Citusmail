// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/auto_reader.dart';

/// For a page whose emails are read ahead of time ([AutoReader], "Read
/// receipts and bookings automatically"): emails it still wants are read
/// soon, and the page looks again as they come in.
mixin ReadsAhead<T extends StatefulWidget> on State<T> {
  AppServices get services;

  /// Loads the page's data again.
  Future<void> reload();

  late final AutoReader _reader = services.autoRead;
  int _seen = 0;

  /// Whether emails are read automatically (else the page offers it).
  bool get readsAhead => services.settings.autoRead;

  /// Whether reading is under way or about to start: the page says so.
  bool get readingAhead => readsAhead && _reader.active;

  @override
  void initState() {
    super.initState();
    _seen = _reader.downloaded;
    _reader.addListener(_changed);
  }

  @override
  void dispose() {
    _reader.removeListener(_changed);
    super.dispose();
  }

  /// After the page loaded: emails it still wants are read shortly.
  void loadedWith(List<int> toRead) {
    if (mounted && readsAhead && toRead.isNotEmpty) {
      _reader.request(after: const Duration(seconds: 2));
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_reader.downloaded != _seen) {
      _seen = _reader.downloaded;
      unawaited(reload());
    }
    setState(() {});
  }
}

/// A small, quiet line while a page's emails are read: "Reading 3
/// receipts…".
final class ReadingQuietly extends StatelessWidget {
  const ReadingQuietly(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Row(
        children: [
          Icon(Icons.downloading_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
