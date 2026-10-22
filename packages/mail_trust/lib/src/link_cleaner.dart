// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Removes tracking parameters from links before they open: the ones
/// that only tell the sender (or an ad network) which email, campaign or
/// person a click came from. The page itself still works without them.
abstract final class LinkCleaner {
  /// Parameter names removed, lower case.
  static const exact = {
    'fbclid',
    'gclid',
    'gclsrc',
    'dclid',
    'gbraid',
    'wbraid',
    'msclkid',
    'yclid',
    'twclid',
    'ttclid',
    'li_fat_id',
    'igshid',
    'mc_cid',
    'mc_eid',
    '_hsenc',
    '_hsmi',
    'hsctatracking',
    'mkt_tok',
    'oly_anon_id',
    'oly_enc_id',
    'vero_id',
    'vero_conv',
    'ml_subscriber',
    'ml_subscriber_hash',
    'rb_clickid',
    's_cid',
    'sc_cid',
    'ck_subscriber_id',
    'ss_source',
    'ss_campaign_id',
    'ss_email_id',
    'trk_contact',
    'trk_msg',
    'trk_module',
    'trk_sid',
    'mbid',
    'cmpid',
    'ef_id',
    '_kx',
    'wickedid',
  };

  /// Prefixes of removed parameter names (`utm_source`, `utm_medium`...).
  static const prefixes = ['utm_', 'pk_', 'mtm_', 'hsa_'];

  static bool isTracking(String name) {
    final n = name.toLowerCase();
    return exact.contains(n) || prefixes.any(n.startsWith);
  }

  /// [link] without tracking parameters, and the names removed. Links that
  /// aren't http(s), or have none, come back unchanged.
  static ({Uri link, List<String> removed}) clean(Uri link) {
    if ((link.scheme != 'http' && link.scheme != 'https') || !link.hasQuery) {
      return (link: link, removed: const []);
    }
    final removed = <String>[];
    final kept = <String>[];
    // Works on the raw query so the order and encoding of what stays is
    // exactly the sender's (servers can be picky).
    for (final part in link.query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final rawName = eq < 0 ? part : part.substring(0, eq);
      String name;
      try {
        name = Uri.decodeQueryComponent(rawName);
      } on ArgumentError {
        name = rawName;
      }
      if (isTracking(name)) {
        removed.add(name);
      } else {
        kept.add(part);
      }
    }
    if (removed.isEmpty) return (link: link, removed: const []);
    final base = link.toString().split('?').first.split('#').first;
    final query = kept.isEmpty ? '' : '?${kept.join('&')}';
    final fragment = link.hasFragment ? '#${link.fragment}' : '';
    return (link: Uri.parse('$base$query$fragment'), removed: removed);
  }
}
