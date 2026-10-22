// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_trust/mail_trust.dart';
import 'package:test/test.dart';

void main() {
  group('Punycode', () {
    test('decodes RFC 3492 samples and lookalikes', () {
      expect(Punycode.decode('pple-43d'), 'аpple'); // Cyrillic а
      expect(Punycode.decode('mnchen-3ya'), 'münchen');
      expect(Punycode.decode('bcher-kva'), 'bücher');
      // RFC 3492 7.1 (L): 3<nen>B<gumi><kinpachi><sensei>
      expect(Punycode.decode('3B-ww4c5e180e575a65lsy2b'), '3年B組金八先生');
    });

    test('rejects invalid input instead of guessing', () {
      expect(Punycode.decode('99999999999999999999'), isNull); // overflow
      expect(Punycode.decode('abc-!'), isNull);
      expect(Punycode.decode('a' * 64), isNull);
      expect(Punycode.decode('ü-abc'), isNull); // non-ASCII basic part
    });
  });

  group('Domains', () {
    test('normalize lowercases and decodes', () {
      expect(Domains.normalize('WWW.Example.COM.'), 'www.example.com');
      expect(Domains.normalize('xn--pple-43d.example'), 'аpple.example');
      expect(Domains.normalize('a..b'), isNull);
      expect(Domains.normalize('xn--invalid!.com'), isNull);
    });

    test('registrable domain follows the Public Suffix List', () {
      expect(Domains.registrable('secure.paypal.co.uk'), 'paypal.co.uk');
      expect(Domains.registrable('a.b.example.com'), 'example.com');
      expect(Domains.registrable('foo.github.io'), 'foo.github.io');
      expect(Domains.registrable('co.uk'), isNull);
      expect(Domains.registrable('localhost'), isNull);
      expect(Domains.registrable('mail.tommykung.cc'), 'tommykung.cc');
      // Unknown endings count as one label.
      expect(Domains.registrable('x.y.unknownending'), 'y.unknownending');
      expect(Domains.registrable('192.168.1.1'), isNull);
      // Wildcard and exception rules (*.ck, !www.ck).
      expect(Domains.registrable('a.b.ck'), 'a.b.ck');
      expect(Domains.registrable('www.ck'), 'www.ck');
    });

    test('IP addresses in every disguise', () {
      for (final h in ['10.0.0.1', '3232235777', '0x7f000001', '[::1]']) {
        expect(Domains.isIpAddress(h), isTrue, reason: h);
      }
      expect(Domains.isIpAddress('example.com'), isFalse);
    });
  });

  group('Lookalikes', () {
    test('mixed alphabets are deceptive, single real ones are not', () {
      expect(Lookalikes.isDeceptive('аpple'), isTrue); // Cyrillic а + Latin
      expect(
        Lookalikes.isDeceptive('раураl'),
        isTrue,
      ); // all Cyrillic lookalikes
      expect(Lookalikes.isDeceptive('пример'), isFalse); // ordinary Russian
      expect(Lookalikes.isDeceptive('münchen'), isFalse);
      expect(Lookalikes.isDeceptive('example'), isFalse);
      expect(Lookalikes.isDeceptive('例え'), isFalse);
    });

    test('skeleton maps imitations to what they imitate', () {
      expect(Lookalikes.skeleton('раураl'), 'paypal');
      expect(Lookalikes.skeleton('paypa1', digits: true), 'paypal');
      expect(Lookalikes.skeleton('arnazon'), 'amazon');
      expect(Lookalikes.skeleton('paypa1'), 'paypa1');
    });
  });

  group('Brands', () {
    test('owned domains', () {
      expect(Brands.owner('paypal.com')?.name, 'PayPal');
      expect(Brands.owner('paypal.co.uk')?.name, 'PayPal');
      expect(Brands.owner('paypal.me')?.name, 'PayPal');
      expect(Brands.owner('paypal.xyz'), isNull);
      expect(Brands.owner('example.com'), isNull);
    });

    test('display names claim a brand only when they are the brand', () {
      expect(Brands.claimedBy('PayPal')?.name, 'PayPal');
      expect(Brands.claimedBy('PayPal Security Team')?.name, 'PayPal');
      expect(Brands.claimedBy('Amazon.co.uk')?.name, 'Amazon');
      expect(Brands.claimedBy('Booking.com')?.name, 'Booking.com');
      expect(Brands.claimedBy('Bank of America')?.name, 'Bank of America');
      expect(Brands.claimedBy('PayPa1')?.name, 'PayPal');
      expect(Brands.claimedBy('Apple Valley Dental'), isNull);
      expect(Brands.claimedBy('Alice Example'), isNull);
      expect(Brands.claimedBy(null), isNull);
      expect(Brands.claimedBy(''), isNull);
    });

    test('lookalike domains', () {
      expect(Brands.imitatedBy('paypa1.example')?.name, 'PayPal');
      expect(Brands.imitatedBy('paypa1-login.example')?.name, 'PayPal');
      expect(Brands.imitatedBy('paypal-login.example')?.name, 'PayPal');
      expect(Brands.imitatedBy('аpple.example')?.name, 'Apple');
      expect(Brands.imitatedBy('arnazon.com')?.name, 'Amazon');
      // Ordinary words are not imitations.
      expect(Brands.imitatedBy('apple-pie.example'), isNull);
      expect(Brands.imitatedBy('apply.example'), isNull);
      expect(Brands.imitatedBy('paypal.com'), isNull);
      expect(Brands.imitatedBy('example.com'), isNull);
    });
  });

  group('RiskyFiles', () {
    test('programs, disguised programs, macros and web pages', () {
      expect(RiskyFiles.check('invoice.pdf.exe')?.level, TrustLevel.danger);
      expect(
        RiskyFiles.check('invoice.pdf.exe')?.reason,
        contains('Pretends to be a .pdf'),
      );
      expect(RiskyFiles.check('setup.EXE')?.level, TrustLevel.danger);
      expect(RiskyFiles.check('terms.docm')?.level, TrustLevel.caution);
      expect(RiskyFiles.check('invoice.html')?.level, TrustLevel.caution);
      expect(RiskyFiles.check('disk.iso')?.level, TrustLevel.caution);
      expect(RiskyFiles.check('report.pdf'), isNull);
      expect(RiskyFiles.check('photo.jpg'), isNull);
      expect(RiskyFiles.check('README'), isNull);
    });
  });

  group('DocumentLinks.shownHost', () {
    test('only whole web addresses count', () {
      expect(
        DocumentLinks.shownHost('https://www.paypal.com/signin'),
        'www.paypal.com',
      );
      expect(DocumentLinks.shownHost('www.paypal.com'), 'www.paypal.com');
      expect(DocumentLinks.shownHost('paypal.com'), 'paypal.com');
      expect(DocumentLinks.shownHost('Click here'), isNull);
      expect(DocumentLinks.shownHost('visit paypal.com'), isNull);
      expect(DocumentLinks.shownHost('invoice.pdf'), isNull);
      expect(DocumentLinks.shownHost('photos.zip'), isNull);
      expect(DocumentLinks.shownHost('me@example.com'), isNull);
      expect(DocumentLinks.shownHost('v1.2'), isNull);
    });
  });
}
