// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// A sender's initials on a color picked from their address. Never a
/// downloaded picture: services like Gravatar would learn who you read.
final class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.address,
    this.size = 36,
  });

  final String name;
  final String address;
  final double size;

  static const _palette = [
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFF8B5CF6),
    Color(0xFF14B8A6),
    Color(0xFFEC4899),
    Color(0xFF64748B),
  ];

  String get _initials {
    final words = name
        .replaceAll(RegExp(r'[<>"@].*'), '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return address.isEmpty ? '?' : address.characters.first.toUpperCase();
    }
    final first = words.first.characters.first;
    final last = words.length > 1 ? words.last.characters.first : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // A stable color per address (not Object.hash, which differs per run).
    var hash = 0;
    for (final unit in address.toLowerCase().codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: _palette[hash % _palette.length],
      child: Text(
        _initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
