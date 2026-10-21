// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// How a listed package may be used.
enum Allowance {
  /// May ship inside the app.
  runtime,

  /// Tests and tooling only. Must never ship.
  dev,
}

/// A package that has been reviewed and approved, with the reason.
class AllowedPackage {
  const AllowedPackage(this.name, this.allowance, this.reason);

  final String name;
  final Allowance allowance;
  final String reason;
}

/// A pattern of package names that is never allowed.
class DenyRule {
  const DenyRule(this.pattern, this.reason);

  final RegExp pattern;
  final String reason;

  bool matches(String packageName) => pattern.hasMatch(packageName);
}

/// The reviewed list of allowed and denied packages.
///
/// File format, one rule per line, `#` starts a comment:
/// ```
/// runtime <name>  <reason>
/// dev     <name>  <reason>
/// deny    <regex> <reason>
/// ```
class DependencyPolicy {
  DependencyPolicy({
    required Map<String, AllowedPackage> allowed,
    required List<DenyRule> denyRules,
  }) : _allowed = Map.unmodifiable(allowed),
       denyRules = List.unmodifiable(denyRules);

  /// Parses the policy text. Throws [FormatException] on any malformed,
  /// duplicate or unknown line so a typo can never weaken the policy.
  factory DependencyPolicy.parse(String text, {String sourceName = 'policy'}) {
    final allowed = <String, AllowedPackage>{};
    final denyRules = <DenyRule>[];
    final lines = text.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final where = '$sourceName:${i + 1}';

      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 3) {
        throw FormatException('$where: expected "<kind> <name> <reason>"');
      }
      final kind = parts[0];
      final subject = parts[1];
      final reason = parts.sublist(2).join(' ');

      switch (kind) {
        case 'runtime' || 'dev':
          if (!_validPackageName.hasMatch(subject)) {
            throw FormatException('$where: "$subject" is not a package name');
          }
          if (allowed.containsKey(subject)) {
            throw FormatException('$where: "$subject" is listed twice');
          }
          final allowance = kind == 'runtime'
              ? Allowance.runtime
              : Allowance.dev;
          allowed[subject] = AllowedPackage(subject, allowance, reason);
        case 'deny':
          final RegExp pattern;
          try {
            pattern = RegExp(subject);
          } on FormatException catch (e) {
            throw FormatException('$where: invalid pattern: ${e.message}');
          }
          denyRules.add(DenyRule(pattern, reason));
        default:
          throw FormatException('$where: unknown kind "$kind"');
      }
    }
    return DependencyPolicy(allowed: allowed, denyRules: denyRules);
  }

  static final _validPackageName = RegExp(r'^[a-z_][a-z0-9_]*$');

  final Map<String, AllowedPackage> _allowed;
  final List<DenyRule> denyRules;

  Iterable<AllowedPackage> get allowedPackages => _allowed.values;

  AllowedPackage? allowedEntry(String packageName) => _allowed[packageName];

  /// The first deny rule matching [packageName], or null.
  DenyRule? denyRuleFor(String packageName) {
    for (final rule in denyRules) {
      if (rule.matches(packageName)) return rule;
    }
    return null;
  }
}
