// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Checks the workspace's dependencies against tool/dependency_policy.txt.
///
/// Run from the repository root after `flutter pub get`:
///   dart run repo_tools:check_dependencies
///
/// Exit codes: 0 passed, 1 policy violations, 2 could not run the check.
library;

import 'dart:io';

import 'package:repo_tools/repo_tools.dart';

const _policyPath = 'tool/dependency_policy.txt';
const _lockPath = 'pubspec.lock';

void main() {
  try {
    final report = _runCheck();
    _printReport(report);
    exitCode = report.passed ? 0 : 1;
  } on Object catch (e) {
    // Fail closed: if the check cannot run, CI must not pass.
    stderr.writeln('Could not run the dependency check: $e');
    exitCode = 2;
  }
}

CheckReport _runCheck() {
  final policy = DependencyPolicy.parse(
    _readFile(_policyPath),
    sourceName: _policyPath,
  );
  final graph = DependencyGraph.fromPubDepsJson(_readPubDeps());
  final lockFile = LockFile.parse(_readFile(_lockPath));
  return DependencyPolicyChecker(
    policy,
    policyPath: _policyPath,
  ).check(graph, lockFile);
}

String _readFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$path not found; run this from the repository root');
  }
  return file.readAsStringSync();
}

String _readPubDeps() {
  final result = Process.runSync('dart', const ['pub', 'deps', '--json']);
  if (result.exitCode != 0) {
    throw StateError(
      '`dart pub deps --json` failed (run `flutter pub get` '
      'first):\n${result.stderr}',
    );
  }
  return result.stdout as String;
}

void _printReport(CheckReport report) {
  for (final finding in report.warnings) {
    stdout.writeln(finding);
  }
  for (final finding in report.errors) {
    stderr.writeln(finding);
  }
  if (report.passed) {
    stdout.writeln(
      'Dependency policy OK: ${report.runtimePackageCount} '
      'runtime and ${report.devPackageCount} dev-only packages reviewed.',
    );
  } else {
    stderr.writeln(
      'Dependency policy FAILED with '
      '${report.errors.length} error(s).',
    );
  }
}
