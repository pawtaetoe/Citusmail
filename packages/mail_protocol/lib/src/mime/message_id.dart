// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

/// Reads and creates Message-IDs (RFC 5322 3.6.4).
///
/// IDs are returned without angle brackets, so `<a@b>` becomes `a@b`.
final class MessageIds {
  const MessageIds({this.maxIds = 500});

  /// References headers can be long; more than this many IDs are dropped
  /// from the start (the newest, most useful ones are at the end).
  final int maxIds;

  static final _bracketed = RegExp(r'<([^<>]*)>');

  /// All IDs in a Message-ID, In-Reply-To or References value, in order,
  /// without duplicates.
  List<String> parseList(String value) {
    final found = <String>[];
    for (final match in _bracketed.allMatches(value)) {
      final id = match.group(1)!.replaceAll(RegExp(r'\s+'), '');
      if (id.isNotEmpty) found.add(id);
    }
    if (found.isEmpty) {
      // Lenient: some mailers omit the brackets.
      found.addAll(
        value.split(RegExp(r'[\s,]+')).where((t) => t.contains('@')),
      );
    }
    // Dart sets keep insertion order: first occurrence wins.
    final unique = found.toSet().toList();
    return unique.length > maxIds
        ? unique.sublist(unique.length - maxIds)
        : unique;
  }

  /// The single ID of a Message-ID field, or null.
  String? parseSingle(String value) {
    final ids = parseList(value);
    return ids.isEmpty ? null : ids.first;
  }

  /// A new random Message-ID for [domain], without brackets. 128 random
  /// bits, so IDs are unique and reveal nothing about the sender's device.
  static String generate(String domain, {Random? random}) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return '$buffer@$domain';
  }
}
