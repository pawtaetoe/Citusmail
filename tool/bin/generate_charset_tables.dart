// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Regenerates the charset tables of mail_protocol from the WHATWG data in
/// tool/third_party/whatwg. Run from the repository root:
///   dart run repo_tools:generate_charset_tables
///
/// Refuses to run if the source files do not match tool/third_party/whatwg/
/// SHA256SUMS, so the tables can only come from reviewed input.
library;

import 'dart:io';

import 'package:repo_tools/repo_tools.dart';

const _sourceDir = 'tool/third_party/whatwg';
const _output = 'packages/mail_protocol/lib/src/charset/whatwg_data.g.dart';

void main() {
  try {
    final checksums = _readChecksums();
    _verifyChecksums(checksums);
    final source = const CharsetTableGenerator().generate(
      encodingsJson: File('$_sourceDir/encodings.json').readAsStringSync(),
      indexesJson: File('$_sourceDir/indexes.json').readAsStringSync(),
      sourceChecksums: checksums,
    );
    File(_output).writeAsStringSync(source);
    stdout.writeln('Wrote $_output (${source.length} bytes)');
  } on Object catch (e) {
    stderr.writeln('Could not generate charset tables: $e');
    exitCode = 1;
  }
}

/// File name -> expected SHA-256, from SHA256SUMS.
Map<String, String> _readChecksums() {
  final file = File('$_sourceDir/SHA256SUMS');
  if (!file.existsSync()) {
    throw StateError('${file.path} not found; run from the repository root');
  }
  final pattern = RegExp(r'^([0-9a-f]{64})\s+\*?(\S+)$');
  final checksums = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    final match = pattern.firstMatch(line.trim());
    if (match == null) {
      throw FormatException('bad line in SHA256SUMS: $line');
    }
    checksums[match.group(2)!] = match.group(1)!;
  }
  return checksums;
}

/// Uses the system's sha256sum so no hashing package is needed. On systems
/// without it the check fails closed.
void _verifyChecksums(Map<String, String> checksums) {
  final result = Process.runSync('sha256sum', [
    '--check',
    '--strict',
    'SHA256SUMS',
  ], workingDirectory: _sourceDir);
  if (result.exitCode != 0) {
    throw StateError(
      'source files do not match SHA256SUMS:\n'
      '${result.stdout}${result.stderr}',
    );
  }
  for (final name in ['encodings.json', 'indexes.json']) {
    if (!checksums.containsKey(name)) {
      throw StateError('SHA256SUMS has no entry for $name');
    }
  }
}
