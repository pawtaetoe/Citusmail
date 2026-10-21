// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:repo_tools/repo_tools.dart';
import 'package:test/test.dart';

void main() {
  const packer = IndexPacker();

  test('round-trips nulls, jumps, decreases and supplementary code points', () {
    final entries = <int?>[
      null,
      0x4E00,
      0x4E01,
      null,
      null,
      0x20,
      0x10FFFF,
      0x3000,
      0,
      null,
    ];
    expect(packer.unpack(packer.pack(entries)), entries);
  });

  test('round-trips an empty index', () {
    expect(packer.unpack(packer.pack(const [])), isEmpty);
  });

  test('rejects values that are not code points', () {
    expect(() => packer.pack([0x110000]), throwsArgumentError);
    expect(() => packer.pack([-1]), throwsArgumentError);
  });

  test('round-trips every real WHATWG index', () {
    final file = File('third_party/whatwg/indexes.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    for (final entry in json.entries) {
      if (entry.key == 'gb18030-ranges') continue;
      final values = (entry.value as List<Object?>).cast<int?>();
      expect(packer.unpack(packer.pack(values)), values, reason: entry.key);
    }
  });
}
