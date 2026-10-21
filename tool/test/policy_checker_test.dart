// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:repo_tools/repo_tools.dart';
import 'package:test/test.dart';

/// Builds `dart pub deps --json` style output for tests.
String pubDepsJson(List<Map<String, Object?>> packages) =>
    jsonEncode({'root': 'workspace', 'packages': packages});

Map<String, Object?> member(
  String name, {
  List<String> deps = const [],
  List<String> devDeps = const [],
}) => {
  'name': name,
  'version': '0.1.0',
  'kind': 'root',
  'source': 'root',
  'dependencies': [...deps, ...devDeps],
  'directDependencies': deps,
  'devDependencies': devDeps,
};

Map<String, Object?> package(
  String name, {
  String source = 'hosted',
  List<String> deps = const [],
}) => {
  'name': name,
  'version': '1.0.0',
  'kind': 'transitive',
  'source': source,
  'dependencies': deps,
  'directDependencies': deps,
};

const pubDevLock = LockFile({allowedPackageHost});

CheckReport runCheck(
  String policyText,
  List<Map<String, Object?>> packages, {
  LockFile lockFile = pubDevLock,
}) {
  final policy = DependencyPolicy.parse(policyText);
  final graph = DependencyGraph.fromPubDepsJson(pubDepsJson(packages));
  return DependencyPolicyChecker(policy).check(graph, lockFile);
}

void main() {
  group('DependencyPolicy.parse', () {
    test('reads runtime, dev and deny rules, ignoring comments', () {
      final policy = DependencyPolicy.parse('''
# comment
runtime meta    used by Flutter
dev     test    test runner

deny    ^sentry crash reporting
''');
      expect(policy.allowedEntry('meta')?.allowance, Allowance.runtime);
      expect(policy.allowedEntry('test')?.allowance, Allowance.dev);
      expect(policy.allowedEntry('test')?.reason, 'test runner');
      expect(policy.denyRuleFor('sentry_flutter')?.reason, 'crash reporting');
      expect(policy.denyRuleFor('meta'), isNull);
    });

    test('rejects a line without a reason', () {
      expect(
        () => DependencyPolicy.parse('runtime meta'),
        throwsFormatException,
      );
    });

    test('rejects an unknown kind', () {
      expect(
        () => DependencyPolicy.parse('allow meta because'),
        throwsFormatException,
      );
    });

    test('rejects a package listed twice', () {
      expect(
        () => DependencyPolicy.parse('runtime meta a\ndev meta b'),
        throwsFormatException,
      );
    });

    test('rejects an invalid package name', () {
      expect(
        () => DependencyPolicy.parse('runtime Bad-Name reason'),
        throwsFormatException,
      );
    });

    test('rejects an invalid deny pattern', () {
      expect(
        () => DependencyPolicy.parse('deny ([ broken'),
        throwsFormatException,
      );
    });
  });

  group('DependencyGraph', () {
    test('rejects output that is not JSON', () {
      expect(
        () => DependencyGraph.fromPubDepsJson('not json'),
        throwsFormatException,
      );
    });

    test('rejects entries missing required fields', () {
      final broken = jsonEncode({
        'packages': [
          {'name': 'meta', 'kind': 'transitive'},
        ],
      });
      expect(
        () => DependencyGraph.fromPubDepsJson(broken),
        throwsFormatException,
      );
    });

    test(
      'runtime closure follows normal deps through members, not dev deps',
      () {
        final graph = DependencyGraph.fromPubDepsJson(
          pubDepsJson([
            member('app', deps: ['protocol'], devDeps: ['test']),
            member('protocol', deps: ['meta'], devDeps: ['lints']),
            package('meta', deps: ['collection']),
            package('collection'),
            package('test', deps: ['shelf']),
            package('shelf'),
            package('lints'),
          ]),
        );
        expect(graph.runtimeClosure(), {'meta', 'collection'});
      },
    );

    test('fails loudly when a referenced package is missing', () {
      final graph = DependencyGraph.fromPubDepsJson(
        pubDepsJson([
          member('app', deps: ['ghost']),
        ]),
      );
      expect(graph.runtimeClosure, throwsStateError);
    });
  });

  group('DependencyPolicyChecker', () {
    test('passes when every package is reviewed', () {
      final report = runCheck('runtime meta ok\ndev test ok', [
        member('app', deps: ['meta'], devDeps: ['test']),
        package('meta'),
        package('test'),
      ]);
      expect(report.passed, isTrue, reason: report.findings.join('\n'));
      expect(report.runtimePackageCount, 1);
      expect(report.devPackageCount, 1);
    });

    test('fails on an unreviewed package', () {
      final report = runCheck('', [
        member('app', deps: ['meta']),
        package('meta'),
      ]);
      expect(report.passed, isFalse);
      expect(report.errors.single.subject, 'meta');
    });

    test('fails when a dev-only package ships in the app', () {
      final report = runCheck('dev meta tests only', [
        member('app', deps: ['meta']),
        package('meta'),
      ]);
      expect(report.passed, isFalse);
      expect(report.errors.single.message, contains('ships in the app'));
    });

    test('fails when a transitive runtime dependency is dev-only', () {
      final report = runCheck('runtime meta ok\ndev collection tests', [
        member('app', deps: ['meta']),
        package('meta', deps: ['collection']),
        package('collection'),
      ]);
      expect(report.errors.single.subject, 'collection');
    });

    test('deny rules win over allow entries and SDK packages', () {
      final report = runCheck(
        'runtime firebase_core ok\ndeny ^firebase telemetry',
        [
          member('app', deps: ['firebase_core', 'firebase_sdk_thing']),
          package('firebase_core'),
          package('firebase_sdk_thing', source: 'sdk'),
        ],
      );
      expect(
        report.errors.map((e) => e.subject),
        unorderedEquals(['firebase_core', 'firebase_sdk_thing']),
      );
    });

    test('fails on git and path sources even if listed', () {
      final report = runCheck('runtime forked ok\ndev local ok', [
        member('app', deps: ['forked'], devDeps: ['local']),
        package('forked', source: 'git'),
        package('local', source: 'path'),
      ]);
      expect(
        report.errors.map((e) => e.subject),
        unorderedEquals(['forked', 'local']),
      );
    });

    test('allows SDK packages without listing them', () {
      final report = runCheck('', [
        member('app', deps: ['flutter']),
        package('flutter', source: 'sdk'),
      ]);
      expect(report.passed, isTrue);
    });

    test('fails on any package host other than https://pub.dev', () {
      for (final host in ['http://pub.dev', 'https://evil.example']) {
        final report = runCheck('', [
          member('app'),
        ], lockFile: LockFile({host}));
        expect(report.passed, isFalse, reason: host);
      }
    });

    test('warns about policy entries that are no longer used', () {
      final report = runCheck('dev old_package gone', [member('app')]);
      expect(report.passed, isTrue);
      expect(report.warnings.single.subject, 'old_package');
    });
  });

  group('LockFile.parse', () {
    test('collects package hosts, quoted or not', () {
      final lock = LockFile.parse('''
packages:
  meta:
    dependency: transitive
    description:
      name: meta
      sha256: abc
      url: "https://pub.dev"
    source: hosted
  other:
    description:
      url: https://mirror.example
''');
      expect(lock.packageHosts, {'https://pub.dev', 'https://mirror.example'});
    });
  });
}
