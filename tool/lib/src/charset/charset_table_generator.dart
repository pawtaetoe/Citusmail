// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'index_packer.dart';

/// Turns the WHATWG `encodings.json` and `indexes.json` into the Dart source
/// of `whatwg_data.g.dart`.
class CharsetTableGenerator {
  const CharsetTableGenerator({this.packer = const IndexPacker()});

  final IndexPacker packer;

  /// Builds the generated Dart file. Throws [FormatException] when the input
  /// does not have the shape the WHATWG publishes.
  String generate({
    required String encodingsJson,
    required String indexesJson,
    required Map<String, String> sourceChecksums,
  }) {
    final labels = _parseLabels(jsonDecode(encodingsJson));
    final indexes = _parseIndexes(jsonDecode(indexesJson));

    final out = StringBuffer()
      ..writeln('// GENERATED FILE. Do not edit by hand.')
      ..writeln('// Regenerate: dart run repo_tools:generate_charset_tables')
      ..writeln('//')
      ..writeln('// Data from the WHATWG Encoding Standard')
      ..writeln('// (https://encoding.spec.whatwg.org/), licensed under the')
      ..writeln('// Creative Commons Attribution 4.0 International License,')
      ..writeln('// (c) WHATWG (Apple, Google, Mozilla, Microsoft).')
      ..writeln('//')
      ..writeln('// Source files (tool/third_party/whatwg):');
    for (final entry in sourceChecksums.entries) {
      out.writeln('//   ${entry.key} sha256 ${entry.value}');
    }
    out
      ..writeln()
      ..writeln('/// Encoding name for every WHATWG label (lowercase).')
      ..writeln('const Map<String, String> whatwgLabels = {');
    for (final label in labels.keys.toList()..sort()) {
      out.writeln("  '${_escape(label)}': '${_escape(labels[label]!)}',");
    }
    out
      ..writeln('};')
      ..writeln()
      ..writeln('/// Packed WHATWG indexes; see CodePointIndex.unpack.')
      ..writeln('const Map<String, String> whatwgPackedIndexes = {');
    for (final name in indexes.keys.toList()..sort()) {
      out.writeln("  '$name':");
      out.writeln("      '${packer.pack(indexes[name]!)}',");
    }
    out.writeln('};');
    return out.toString();
  }

  /// Label -> encoding name, from encodings.json.
  Map<String, String> _parseLabels(Object? json) {
    final labels = <String, String>{};
    for (final group in _list(json, 'encodings.json')) {
      final encodings = _list(_map(group, 'group')['encodings'], 'encodings');
      for (final encoding in encodings) {
        final map = _map(encoding, 'encoding');
        final name = _string(map['name'], 'name').toLowerCase();
        for (final label in _list(map['labels'], '$name.labels')) {
          final key = _string(label, 'label').toLowerCase();
          final existing = labels[key];
          if (existing != null && existing != name) {
            throw FormatException('label "$key" maps to $existing and $name');
          }
          labels[key] = name;
        }
      }
    }
    if (labels.length < 200) {
      throw FormatException('only ${labels.length} labels; input looks wrong');
    }
    return labels;
  }

  /// Index name -> entries. gb18030-ranges is flattened to
  /// [pointer0, codePoint0, pointer1, codePoint1, ...].
  Map<String, List<int?>> _parseIndexes(Object? json) {
    final indexes = <String, List<int?>>{};
    for (final entry in _map(json, 'indexes.json').entries) {
      final values = _list(entry.value, entry.key);
      if (entry.key == 'gb18030-ranges') {
        indexes[entry.key] = [
          for (final pair in values)
            for (final v in _list(pair, 'range')) _int(v, 'range value'),
        ];
      } else {
        indexes[entry.key] = [
          for (final v in values) v == null ? null : _int(v, entry.key),
        ];
      }
    }
    for (final required in const ['big5', 'euc-kr', 'gb18030', 'jis0208']) {
      if (!indexes.containsKey(required)) {
        throw FormatException('indexes.json has no "$required" index');
      }
    }
    return indexes;
  }

  static String _escape(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');

  static Map<String, Object?> _map(Object? v, String what) =>
      v is Map<String, Object?>
      ? v
      : throw FormatException('expected an object for $what');

  static List<Object?> _list(Object? v, String what) => v is List<Object?>
      ? v
      : throw FormatException('expected a list for $what');

  static String _string(Object? v, String what) =>
      v is String ? v : throw FormatException('expected a string for $what');

  static int _int(Object? v, String what) =>
      v is int ? v : throw FormatException('expected an integer for $what');
}
