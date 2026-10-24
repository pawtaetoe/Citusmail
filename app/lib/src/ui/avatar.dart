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

  /// Muted, distinct hues; white initials stay above 4.5:1 on each.
  static const _palette = [
    Color(0xFF2F6F8F),
    Color(0xFF3D7A4A),
    Color(0xFF9A5B13),
    Color(0xFFB03A48),
    Color(0xFF6B4FA0),
    Color(0xFF0F7A69),
    Color(0xFFA23E7C),
    Color(0xFF55636E),
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
