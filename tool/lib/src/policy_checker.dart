// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dependency_graph.dart';
import 'dependency_policy.dart';
import 'lock_file.dart';

/// The only package host allowed. HTTPS is part of the match on purpose.
const String allowedPackageHost = 'https://pub.dev';

enum Severity { error, warning }

/// One finding of the check.
class Finding {
  const Finding(this.severity, this.subject, this.message);

  final Severity severity;

  /// The package or host the finding is about.
  final String subject;
  final String message;

  @override
  String toString() => '${severity.name}: $subject: $message';
}

/// The outcome of a policy check.
class CheckReport {
  CheckReport({
    required List<Finding> findings,
    required this.runtimePackageCount,
    required this.devPackageCount,
  }) : findings = List.unmodifiable(findings);

  final List<Finding> findings;
  final int runtimePackageCount;
  final int devPackageCount;

  Iterable<Finding> get errors =>
      findings.where((f) => f.severity == Severity.error);

  Iterable<Finding> get warnings =>
      findings.where((f) => f.severity == Severity.warning);

  bool get passed => errors.isEmpty;
}

/// Compares the resolved dependency graph and lock file with the policy.
class DependencyPolicyChecker {
  const DependencyPolicyChecker(this.policy, {this.policyPath = 'policy'});

  final DependencyPolicy policy;

  /// Shown in fix-it hints so the reader knows which file to edit.
  final String policyPath;

  CheckReport check(DependencyGraph graph, LockFile lockFile) {
    final findings = <Finding>[];
    final shipped = graph.runtimeClosure();
    var devCount = 0;

    for (final package in graph.packages) {
      if (package.isWorkspaceMember) continue;
      final ships = shipped.contains(package.name);
      if (!ships) devCount++;
      findings.addAll(_checkPackage(package, ships: ships));
    }

    findings.addAll(_checkStaleEntries(graph));
    findings.addAll(_checkHosts(lockFile));

    return CheckReport(
      findings: findings,
      runtimePackageCount: shipped.length,
      devPackageCount: devCount,
    );
  }

  Iterable<Finding> _checkPackage(
    PackageNode package, {
    required bool ships,
  }) sync* {
    final name = package.name;

    // Deny rules win over everything, including SDK packages and allow entries.
    final denyRule = policy.denyRuleFor(name);
    if (denyRule != null) {
      yield Finding(Severity.error, name, 'denied (${denyRule.reason})');
      return;
    }

    switch (package.source) {
      case PackageSource.workspace:
      case PackageSource.sdk:
        return;
      case PackageSource.other:
        yield Finding(
          Severity.error,
          name,
          'comes from "${package.rawSource}"; only $allowedPackageHost is allowed',
        );
        return;
      case PackageSource.hosted:
        break;
    }

    final entry = policy.allowedEntry(name);
    if (entry == null) {
      final kind = ships ? 'runtime' : 'dev';
      yield Finding(
        Severity.error,
        name,
        'not reviewed. Check it, then add "$kind $name <reason>" to $policyPath',
      );
    } else if (ships && entry.allowance != Allowance.runtime) {
      yield Finding(
        Severity.error,
        name,
        'listed as dev-only but ships in the app. Review it for runtime use, '
        'then change it to "runtime" in $policyPath',
      );
    }
  }

  Iterable<Finding> _checkStaleEntries(DependencyGraph graph) sync* {
    for (final entry in policy.allowedPackages) {
      if (!graph.contains(entry.name)) {
        yield Finding(
          Severity.warning,
          entry.name,
          'listed in $policyPath but no longer used; remove it',
        );
      }
    }
  }

  Iterable<Finding> _checkHosts(LockFile lockFile) sync* {
    for (final host in lockFile.packageHosts) {
      if (host != allowedPackageHost) {
        yield Finding(
          Severity.error,
          host,
          'pubspec.lock downloads from this host; only $allowedPackageHost is allowed',
        );
      }
    }
  }
}
