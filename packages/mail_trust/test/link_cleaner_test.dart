// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_trust/mail_trust.dart';
import 'package:test/test.dart';

void main() {
  /// The cleaned link and the removed names, joined for easy comparing.
  (String, String) clean(String url) {
    final r = LinkCleaner.clean(Uri.parse(url));
    return (r.link.toString(), r.removed.join(','));
  }

  test('tracking parameters go, the rest stays as written', () {
    expect(
      clean(
        'https://shop.example/deals?utm_source=newsletter&id=7&UTM_Medium=email'
        '&q=a%20b&fbclid=xyz&mc_eid=abc#top',
      ),
      (
        'https://shop.example/deals?id=7&q=a%20b#top',
        'utm_source,UTM_Medium,fbclid,mc_eid',
      ),
    );
  });

  test('nothing to remove: unchanged', () {
    for (final url in [
      'https://shop.example/deals?id=7',
      'https://shop.example/',
      'mailto:a@b.example?subject=utm_source',
    ]) {
      expect(clean(url), (url, ''), reason: url);
    }
  });

  test('only tracking parameters: the question mark goes too', () {
    expect(clean('https://shop.example/p?utm_campaign=x&_hsenc=y'), (
      'https://shop.example/p',
      'utm_campaign,_hsenc',
    ));
  });

  test('broken encoding in a name does not throw', () {
    expect(clean('https://shop.example/p?a=%E0%A4&utm_id=2').$2, 'utm_id');
  });
}
