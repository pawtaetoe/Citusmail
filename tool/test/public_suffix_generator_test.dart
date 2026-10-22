// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:repo_tools/repo_tools.dart';
import 'package:test/test.dart';

void main() {
  const generator = PublicSuffixGenerator();
  String root(String path) => '../$path';

  test('the generated table matches the vendored list', () {
    final generated = generator.generate(
      File(root(PublicSuffixGenerator.input)).readAsBytesSync(),
      PublicSuffixGenerator.checksumFrom(
        File(root(PublicSuffixGenerator.sums)).readAsStringSync(),
      ),
    );
    expect(
      File(root(PublicSuffixGenerator.output)).readAsStringSync(),
      generated,
      reason: 'run dart run repo_tools:generate_public_suffixes',
    );
  });

  test('rules: comments skipped, wildcards and exceptions kept', () {
    final list = Uint8List.fromList(
      utf8.encode(
        '// comment\n\nCOM\nco.uk  trailing text\n*.ck\n!www.ck\nit\'s\n',
      ),
    );
    final out = generator.generate(list, sha256.convert(list).toString());
    expect(out, contains("  'com',\n"));
    expect(out, contains("  'co.uk',\n"));
    expect(out, contains("  '*.ck',\n"));
    expect(out, contains("  '!www.ck',\n"));
    expect(out, contains(r"  'it\'s',"));
    expect(out, isNot(contains('comment\',')));
  });

  test('a list that is not the reviewed one is refused', () {
    final list = Uint8List.fromList(utf8.encode('com\n'));
    expect(() => generator.generate(list, '0' * 64), throwsFormatException);
  });
}
