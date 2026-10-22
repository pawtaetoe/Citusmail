// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Spots tracking pixels: images whose only job is to tell the sender that
/// (and when, and from where) a message was opened. They are never
/// loaded, even when the user loads a message's images.
abstract final class TrackingPixels {
  /// Hosts that serve nothing but open tracking (and their subdomains).
  static const trackingHosts = {
    'awstrack.me', // Amazon SES
    'mailtrack.io',
    'mltrk.io',
    'mandrillapp.com',
    'trk.klaviyomail.com',
    'track.hubspot.com',
    'hubspotlinks.com',
    'hubspotemail.net',
    'open.convertkit-mail.com',
    'open.substack.com',
    'pixel.wp.com',
    'pixel.inbox.exacttarget.com',
    'cl.exct.net',
    'tracking.tldrnewsletter.com',
    'email.mg.mailgun.org',
    'counter.yesware.com',
    't.yesware.com',
    'app.getresponse.com',
    'trk.cp20.com',
    'mailstat.us',
    'bl-1.com',
    'go.pardot.com',
    'trk.mail.ru',
    'ea.pstmrk.it', // Postmark
    'track.customer.io',
    'e.customeriomail.com',
    'clicks.beehiiv.com',
    'opens.beehiiv.com',
  };

  /// Paths typical of open-tracking endpoints on any host.
  static final _trackingPath = RegExp(
    r'(/track(ing)?/open|/open\.(php|aspx|gif|png)|/wf/open|/e/o/|/o/[a-z0-9_-]{8,}|'
    r'/pixel(\.|/|$)|/beacon(\.|/|$)|/trk(\.|/|$)|/imp(\?|$)|/openrate|/emimp/|/ss/o/)',
    caseSensitive: false,
  );

  /// Whether an image is a tracker: tiny (2 px or less on a side, from
  /// attributes or inline style), invisible (`opacity: 0`), from a
  /// tracking host, or at a typical tracking path.
  static bool isTracker(
    Uri url, {
    double? width,
    double? height,
    String? style,
  }) {
    if ((width != null && width <= 2) || (height != null && height <= 2)) {
      return true;
    }
    if (style != null) {
      final s = style.toLowerCase().replaceAll(RegExp(r'\s'), '');
      if (RegExp(r'(^|;)(max-)?(width|height):[0-2](\.\d+)?(px)?(;|$)')
              .hasMatch(s) ||
          RegExp(r'(^|;)opacity:0(\.0+)?(;|$)').hasMatch(s)) {
        return true;
      }
    }
    final host = url.host.toLowerCase();
    for (final tracker in trackingHosts) {
      if (host == tracker || host.endsWith('.$tracker')) return true;
    }
    return _trackingPath.hasMatch(url.path);
  }
}
