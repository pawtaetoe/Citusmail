// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Link protection services rewrite every link in a message so a click
/// passes their check first: Outlook and Hotmail (Safe Links), Proofpoint,
/// Google and Barracuda. The real destination is inside the rewritten
/// address. Checks compare what a link shows with where it really goes,
/// so they look through these wrappers. Each one is recognised only on
/// its own service's exact host, so a lookalike can't use this to hide.
abstract final class LinkWrappers {
  /// The address [link] leads to once its protection wrappers (up to
  /// three, nested) are taken off; [link] itself when it has none.
  static Uri unwrap(Uri link) {
    var current = link;
    for (var i = 0; i < 3; i++) {
      final inner = _inner(current);
      if (inner == null) break;
      current = inner;
    }
    return current;
  }

  static Uri? _inner(Uri link) {
    final host = link.host.toLowerCase();
    final String? target;
    if (host.endsWith('.safelinks.protection.outlook.com')) {
      target = link.queryParameters['url'];
    } else if (host == 'urldefense.proofpoint.com' &&
        link.path.startsWith('/v2/url')) {
      // u=https-3A__example.com_path : "-" is "%", "_" is "/".
      final u = link.queryParameters['u'];
      target = u == null
          ? null
          : _decode(u.replaceAll('-', '%').replaceAll('_', '/'));
    } else if (host == 'urldefense.com' && link.path.startsWith('/v3/__')) {
      final path = link.path.substring('/v3/__'.length);
      final end = path.indexOf('__;');
      target = end < 0 ? null : path.substring(0, end);
    } else if ((host == 'www.google.com' || host == 'google.com') &&
        link.path == '/url') {
      target = link.queryParameters['q'] ?? link.queryParameters['url'];
    } else if (host == 'linkprotect.cudasvc.com' && link.path == '/url') {
      target = link.queryParameters['a'];
    } else {
      return null;
    }
    if (target == null) return null;
    final inner = Uri.tryParse(target.trim());
    if (inner == null ||
        (inner.scheme != 'http' && inner.scheme != 'https') ||
        inner.host.isEmpty) {
      return null;
    }
    return inner;
  }

  static String? _decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
}
