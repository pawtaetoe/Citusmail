// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// Where a package in the resolved graph comes from.
enum PackageSource {
  /// A package of this repository's workspace.
  workspace,

  /// Downloaded from a package host (pub.dev).
  hosted,

  /// Shipped with the Dart or Flutter SDK.
  sdk,

  /// Anything else (git, path). Not allowed by policy.
  other,
}

/// One package in the resolved dependency graph.
class PackageNode {
  const PackageNode({
    required this.name,
    required this.version,
    required this.source,
    required this.rawSource,
    required this.runtimeDependencies,
  });

  final String name;
  final String version;
  final PackageSource source;

  /// The source exactly as pub reported it, for error messages.
  final String rawSource;

  /// Dependencies that are loaded at runtime. For workspace members this
  /// excludes dev_dependencies. For other packages pub only resolves their
  /// normal dependencies, so all of them count.
  final List<String> runtimeDependencies;

  bool get isWorkspaceMember => source == PackageSource.workspace;
}

/// The resolved dependency graph of the whole workspace, built from the
/// output of `dart pub deps --json`.
class DependencyGraph {
  DependencyGraph(Iterable<PackageNode> nodes)
    : _nodes = {for (final n in nodes) n.name: n};

  /// Parses `dart pub deps --json` output. Throws [FormatException] when the
  /// output does not have the expected shape, so a format change in pub can
  /// never silently skip packages.
  factory DependencyGraph.fromPubDepsJson(String jsonText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw FormatException('pub deps output is not JSON: ${e.message}');
    }
    final root = _expectMap(decoded, 'pub deps output');
    final packages = _expectList(root['packages'], 'packages');
    return DependencyGraph(
      packages.map((p) => _parseNode(_expectMap(p, 'package entry'))),
    );
  }

  final Map<String, PackageNode> _nodes;

  Iterable<PackageNode> get packages => _nodes.values;

  bool contains(String name) => _nodes.containsKey(name);

  PackageNode? operator [](String name) => _nodes[name];

  /// Every non-workspace package that can be loaded at runtime by any
  /// workspace member. This is deliberately conservative: a package used at
  /// runtime by any member counts as shipping, even if that member is a tool.
  Set<String> runtimeClosure() {
    final shipped = <String>{};
    final pending = <String>[
      for (final member in packages.where((p) => p.isWorkspaceMember))
        ...member.runtimeDependencies,
    ];
    final visitedMembers = <String>{};
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      final node = _nodes[name];
      if (node == null) {
        throw StateError(
          'Package "$name" is referenced but missing from the '
          'graph; re-run `flutter pub get`',
        );
      }
      if (node.isWorkspaceMember) {
        if (visitedMembers.add(name)) pending.addAll(node.runtimeDependencies);
        continue;
      }
      if (shipped.add(name)) pending.addAll(node.runtimeDependencies);
    }
    return shipped;
  }

  static PackageNode _parseNode(Map<String, Object?> json) {
    final name = _expectString(json['name'], 'name');
    final kind = _expectString(json['kind'], '$name.kind');
    final rawSource = _expectString(json['source'], '$name.source');
    final isMember = kind == 'root';
    final runtimeKey = isMember ? 'directDependencies' : 'dependencies';
    return PackageNode(
      name: name,
      version: _expectString(json['version'], '$name.version'),
      source: isMember ? PackageSource.workspace : _parseSource(rawSource),
      rawSource: rawSource,
      runtimeDependencies: _expectList(json[runtimeKey], '$name.$runtimeKey')
          .map((d) {
            return _expectString(d, '$name.$runtimeKey[]');
          })
          .toList(growable: false),
    );
  }

  static PackageSource _parseSource(String source) => switch (source) {
    'hosted' => PackageSource.hosted,
    'sdk' => PackageSource.sdk,
    _ => PackageSource.other,
  };

  static Map<String, Object?> _expectMap(Object? value, String what) {
    if (value is Map<String, Object?>) return value;
    throw FormatException('Expected an object for $what');
  }

  static List<Object?> _expectList(Object? value, String what) {
    if (value is List<Object?>) return value;
    throw FormatException('Expected a list for $what');
  }

  static String _expectString(Object? value, String what) {
    if (value is String && value.isNotEmpty) return value;
    throw FormatException('Expected a non-empty string for $what');
  }
}
