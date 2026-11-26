// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'import_checker.dart' show ImportViolation;

/// Keeps the app's layers apart (see docs/architecture.md):
///
/// - `core/` imports no feature, no service and nothing from `app/`.
/// - Services and every `state/` folder import no widget code: no `ui/`
///   folder, no `core/widgets/`, no `package:flutter/material.dart`.
///
/// Paths are repository relative; only files under [appSource] are
/// checked.
final class LayerChecker {
  const LayerChecker({this.appSource = 'app/lib/src/'});

  /// Where the app's code lives.
  final String appSource;

  static final _directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  );

  List<ImportViolation> check(String path, String content) {
    final file = _normalize(path);
    if (!file.startsWith(appSource)) return const [];
    final here = file.substring(appSource.length);
    final inCore = here.startsWith('core/');
    final noWidgets = here.startsWith('services/') || here.contains('/state/');
    if (!inCore && !noWidgets) return const [];

    final violations = <ImportViolation>[];
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final match = _directive.firstMatch(lines[i]);
      if (match == null) continue;
      final uri = match.group(1)!;
      if (noWidgets && uri == 'package:flutter/material.dart') {
        violations.add(
          ImportViolation(
            path,
            i + 1,
            'services and state hold no widgets: use '
            'package:flutter/foundation.dart (or widgets.dart for keys)',
          ),
        );
        continue;
      }
      final target = _target(here, uri);
      if (target == null) continue;
      if (inCore &&
          (target.startsWith('features/') ||
              target.startsWith('services/') ||
              target.startsWith('app/'))) {
        violations.add(
          ImportViolation(
            path,
            i + 1,
            'core/ is shared by every feature and depends on none '
            '(it imports $target)',
          ),
        );
      }
      if (noWidgets &&
          (target.contains('/ui/') || target.startsWith('core/widgets/'))) {
        violations.add(
          ImportViolation(
            path,
            i + 1,
            'services and state import no widget code (it imports $target)',
          ),
        );
      }
    }
    return violations;
  }

  /// The imported file relative to [appSource], or null if it is outside
  /// the app's code (another package, the SDK).
  String? _target(String here, String uri) {
    const self = 'package:citusmail/src/';
    if (uri.startsWith(self)) return uri.substring(self.length);
    if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
    final parts = here.split('/')..removeLast();
    for (final segment in uri.split('/')) {
      if (segment == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else if (segment != '.') {
        parts.add(segment);
      }
    }
    return parts.join('/');
  }

  static String _normalize(String path) {
    final p = path.replaceAll(r'\', '/');
    return p.startsWith('./') ? p.substring(2) : p;
  }
}
