// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Generates packages/mail_trust/lib/src/generated/public_suffixes.g.dart
/// from tool/third_party/publicsuffix/public_suffix_list.dat, refusing a
/// list whose checksum is not the reviewed one.
///
/// Run from the repository root:
///   dart run repo_tools:generate_public_suffixes
library;

import 'dart:io';

import 'package:repo_tools/repo_tools.dart';

void main() {
  const generator = PublicSuffixGenerator();
  final String source;
  try {
    source = generator.generate(
      File(PublicSuffixGenerator.input).readAsBytesSync(),
      PublicSuffixGenerator.checksumFrom(
        File(PublicSuffixGenerator.sums).readAsStringSync(),
      ),
    );
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exitCode = 1;
    return;
  }
  File(PublicSuffixGenerator.output)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(source);
  stdout.writeln('wrote ${PublicSuffixGenerator.output}');
}
