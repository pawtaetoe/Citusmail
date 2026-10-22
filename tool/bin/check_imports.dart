// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Fails if shipped code imports network libraries it must not.
///
/// Run from the repository root:
///   dart run repo_tools:check_imports
library;

import 'dart:io';

import 'package:repo_tools/repo_tools.dart';

void main() {
  final checker = ImportChecker();
  final roots = [
    Directory('app/lib'),
    ...Directory('packages')
        .listSync()
        .whereType<Directory>()
        .map((d) => Directory('${d.path}/lib')),
  ].where((d) => d.existsSync());
  if (roots.isEmpty) {
    stderr.writeln('Run from the repository root.');
    exitCode = 2;
    return;
  }
  final violations = [
    for (final root in roots)
      for (final file in root.listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart'))
          ...checker.check(file.path, file.readAsStringSync()),
  ];
  for (final v in violations) {
    stderr.writeln('error: $v');
  }
  if (violations.isEmpty) {
    stdout.writeln('Import check OK: ${roots.length} source folders.');
  } else {
    exitCode = 1;
  }
}
