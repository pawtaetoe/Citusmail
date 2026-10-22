// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'domains.dart';

/// A company that phishing mail often pretends to be, with the domains it
/// really sends mail and links from.
final class Brand {
  const Brand(
    this.name,
    this.labels, {
    this.domains = const {},
    this.distinctive = true,
  });

  /// As shown to people.
  final String name;

  /// Domain names the company uses under `.com` and country endings,
  /// e.g. `paypal` for `paypal.com` and `paypal.de`.
  final Set<String> labels;

  /// Other registrable domains it uses (`paypal.me`, `apple.news`).
  final Set<String> domains;

  /// Whether the name is unusual enough that `paypal-login.example`
  /// clearly refers to it. Ordinary words (Apple, Chase) are not: there
  /// are many honest `apple-pie` sites.
  final bool distinctive;

  /// Whether [registrable] (a registrable domain) belongs to this brand.
  bool owns(String registrable) {
    if (domains.contains(registrable)) return true;
    final dot = registrable.indexOf('.');
    if (dot < 0) return false;
    final label = registrable.substring(0, dot);
    final suffix = registrable.substring(dot + 1);
    return labels.contains(label) && Brands._usualSuffix(suffix);
  }
}

/// The brand table and the questions asked of it.
abstract final class Brands {
  static const all = [
    Brand(
      'PayPal',
      {'paypal'},
      domains: {'paypal.me', 'paypal-communication.com', 'paypalobjects.com'},
    ),
    Brand(
      'Apple',
      {'apple', 'icloud'},
      domains: {'apple.news', 'me.com', 'mac.com', 'itunes.com'},
      distinctive: false,
    ),
    Brand('iCloud', {'icloud'}, domains: {'apple.com', 'me.com'}),
    Brand(
      'Microsoft',
      {
        'microsoft',
        'outlook',
        'office',
        'office365',
        'live',
        'hotmail',
        'xbox',
        'onedrive',
        'skype',
        'bing',
        'msn',
      },
      domains: {
        'microsoftonline.com',
        'sharepoint.com',
        'windows.com',
        'windowsupdate.com',
        'azure.com',
        'microsoft365.com',
        'msftauth.net',
        'aka.ms',
        'msft.net',
      },
    ),
    Brand(
      'Outlook',
      {'outlook', 'microsoft', 'live', 'hotmail', 'office'},
      domains: {'microsoftonline.com'},
      distinctive: false,
    ),
    Brand(
      'Office 365',
      {'office', 'office365', 'microsoft', 'outlook'},
      domains: {'microsoftonline.com', 'microsoft365.com', 'sharepoint.com'},
    ),
    Brand(
      'OneDrive',
      {'onedrive', 'microsoft', 'live'},
      domains: {'sharepoint.com', '1drv.ms'},
    ),
    Brand(
      'Google',
      {'google', 'gmail', 'googlemail', 'youtube'},
      domains: {
        'withgoogle.com',
        'goo.gl',
        'g.co',
        'googleusercontent.com',
        'gstatic.com',
        'google.dev',
        'web.app',
      },
    ),
    Brand('Gmail', {'gmail', 'google', 'googlemail'}),
    Brand('YouTube', {'youtube', 'google'}, domains: {'youtu.be'}),
    Brand(
      'Amazon',
      {'amazon', 'amazonaws', 'aws', 'primevideo'},
      domains: {
        'amzn.com',
        'amzn.to',
        'a.co',
        'amazon.dev',
        'media-amazon.com',
        'ssl-images-amazon.com',
      },
      distinctive: false,
    ),
    Brand(
      'Netflix',
      {'netflix'},
      domains: {'nflxext.com', 'nflximg.net', 'nflxso.net'},
    ),
    Brand(
      'Facebook',
      {'facebook', 'facebookmail', 'meta'},
      domains: {'fb.com', 'fb.me', 'fbcdn.net', 'metamail.com'},
    ),
    Brand(
      'Instagram',
      {'instagram', 'facebookmail', 'meta'},
      domains: {'instagr.am'},
    ),
    Brand(
      'WhatsApp',
      {'whatsapp', 'facebookmail', 'meta'},
      domains: {'wa.me', 'whatsapp.net'},
    ),
    Brand(
      'Meta',
      {'meta', 'facebook', 'facebookmail'},
      domains: {'metamail.com'},
      distinctive: false,
    ),
    Brand('LinkedIn', {'linkedin'}, domains: {'lnkd.in', 'licdn.com'}),
    Brand('Twitter', {'twitter'}, domains: {'t.co', 'twimg.com', 'x.com'}),
    Brand('DocuSign', {'docusign'}, domains: {'docusign.net'}),
    Brand(
      'Dropbox',
      {'dropbox', 'dropboxmail'},
      domains: {'db.tt', 'dropboxusercontent.com'},
    ),
    Brand(
      'Adobe',
      {'adobe'},
      domains: {'adobesign.com', 'acrobat.com', 'adobelogin.com'},
    ),
    Brand(
      'DHL',
      {'dhl'},
      domains: {'dpdhl.com', 'deutschepost.de'},
      distinctive: false,
    ),
    Brand('FedEx', {'fedex'}),
    Brand('UPS', {'ups'}, distinctive: false),
    Brand('USPS', {'usps'}, domains: {'usps.gov'}),
    Brand(
      'Royal Mail',
      {'royalmail'},
      domains: {'royalmail.co.uk', 'royalmailgroup.com'},
    ),
    Brand('eBay', {'ebay'}, domains: {'ebay.co.uk', 'ebaystatic.com'}),
    Brand('Coinbase', {'coinbase'}, domains: {'coinbase-mail.com'}),
    Brand('Binance', {'binance'}),
    Brand('MetaMask', {'metamask'}, domains: {'metamask.io'}),
    Brand('Chase', {'chase', 'jpmorgan', 'jpmorganchase'}, distinctive: false),
    Brand('Bank of America', {'bankofamerica', 'bofa'}),
    Brand('Wells Fargo', {'wellsfargo'}),
    Brand('Citibank', {'citi', 'citibank', 'citigroup'}),
    Brand('HSBC', {'hsbc'}),
    Brand('Barclays', {'barclays', 'barclaycard'}),
    Brand('Revolut', {'revolut'}),
    Brand('Wise', {'wise', 'transferwise'}, distinctive: false),
    Brand(
      'American Express',
      {'americanexpress', 'amex', 'aexp'},
      domains: {'aexp-static.com'},
    ),
    Brand('Visa', {'visa'}, distinctive: false),
    Brand('Mastercard', {'mastercard'}),
    Brand(
      'Steam',
      {'steampowered', 'steamcommunity'},
      domains: {'steamstatic.com', 'valvesoftware.com'},
      distinctive: false,
    ),
    Brand('Spotify', {'spotify'}, domains: {'spoti.fi', 'scdn.co'}),
    Brand('Uber', {'uber'}),
    Brand('Airbnb', {'airbnb'}, domains: {'airbnbmail.com'}),
    Brand('Booking.com', {'booking'}, distinctive: false),
    Brand(
      'GitHub',
      {'github'},
      domains: {'githubusercontent.com', 'github.io', 'githubassets.com'},
    ),
    Brand(
      'Zoom',
      {'zoom'},
      domains: {'zoom.us', 'zoomgov.com'},
      distinctive: false,
    ),
    Brand('Telegram', {'telegram'}, domains: {'t.me', 'telegram.org'}),
    Brand('Discord', {'discord', 'discordapp'}, domains: {'discord.gg'}),
    Brand('Norton', {'norton', 'nortonlifelock'}, distinctive: false),
    Brand('McAfee', {'mcafee'}),
  ];

  /// Words that may come with a brand in a display name without making
  /// it a different name: "PayPal Security Team", "Amazon.com".
  static const _generic = {
    'account',
    'accounts',
    'alert',
    'alerts',
    'billing',
    'care',
    'center',
    'centre',
    'com',
    'customer',
    'customers',
    'department',
    'do',
    'help',
    'id',
    'inc',
    'info',
    'llc',
    'ltd',
    'mail',
    'no',
    'noreply',
    'not',
    'notice',
    'notification',
    'notifications',
    'official',
    'online',
    'reply',
    'secure',
    'security',
    'service',
    'services',
    'support',
    'team',
    'the',
    'verification',
    'via',
  };

  /// The brand a display name claims to be ("PayPal", "Apple Support",
  /// "Amazon.co.uk"), or null. Only names made of the brand and words like
  /// "support" or "team" count, so "Apple Valley Dental" is not Apple.
  static Brand? claimedBy(String? displayName) {
    if (displayName == null) return null;
    final key = _key(displayName);
    if (key.isEmpty) return null;
    for (final brand in all) {
      if (_key(brand.name) == key) return brand;
    }
    return null;
  }

  /// A name reduced to what identifies it: lookalike letters replaced,
  /// generic words and a trailing domain ending dropped, joined.
  static String _key(String name) {
    final words = Lookalikes.skeleton(name.toLowerCase(), digits: true)
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty && !_generic.contains(w))
        .toList();
    // "Amazon.co.uk" -> "amazon".
    for (var i = 1; i < words.length; i++) {
      if (_usualSuffix(words.sublist(i).join('.'))) {
        words.removeRange(i, words.length);
        break;
      }
    }
    return words.join();
  }

  /// The brand that owns [registrable], or null.
  static Brand? owner(String registrable) {
    for (final brand in all) {
      if (brand.owns(registrable)) return brand;
    }
    return null;
  }

  /// The brand [registrable] imitates, or null: a lookalike of its name
  /// (`paypa1.example`, `аpple.example` with a Cyrillic "а") or, for
  /// distinctive names, the name with extra words
  /// (`paypal-login.example`). A domain the brand owns imitates nothing.
  static Brand? imitatedBy(String registrable) {
    if (owner(registrable) != null) return null;
    final dot = registrable.indexOf('.');
    final label = dot < 0 ? registrable : registrable.substring(0, dot);
    final skeleton = Lookalikes.skeleton(label, digits: true);
    final parts = skeleton.split('-');
    for (final brand in all) {
      for (final name in brand.labels) {
        if (name.length < 4) continue; // "ups", "dhl": too short to tell
        final target = Lookalikes.skeleton(name, digits: true);
        if (skeleton == target && label != name) return brand;
        if (brand.distinctive && parts.length > 1 && parts.contains(target)) {
          return brand;
        }
      }
    }
    return null;
  }

  /// `.com`, `.net`, `.org` and country endings (`.de`, `.co.uk`,
  /// `.com.au`): where companies register their own name in many places.
  static bool _usualSuffix(String suffix) {
    if (const {'com', 'net', 'org'}.contains(suffix)) return true;
    final parts = suffix.split('.');
    final country = parts.last;
    if (country.length != 2 || !RegExp(r'^[a-z]{2}$').hasMatch(country)) {
      return false;
    }
    return parts.length == 1 ||
        (parts.length == 2 &&
            const {
              'co',
              'com',
              'net',
              'org',
              'ne',
              'or',
            }.contains(parts.first));
  }
}
