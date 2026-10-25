// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_view/mail_view.dart';
import 'package:mail_web/mail_web.dart';
import 'package:test/test.dart';

const _context = TrustContext(trustedAuthServId: 'mail.citusmail.test');

MessageView _fixture(String path) =>
    MessageView.parse(File('../../test-data/mail/$path').readAsBytesSync());

MessageView _mail(String headers) => MessageView.parse(
  Uint8List.fromList(
    utf8.encode('${headers.trim()}\nContent-Type: text/plain\n\nHello\n'),
  ),
);

UnsubscribePlan _plan(MessageView view, [TrustContext context = _context]) =>
    UnsubscribePlanner.plan(
      view.message,
      const TrustChecker().check(view, context),
    );

HeaderSection _headers(String text) => const HeaderParser()
    .parse(Uint8List.fromList(utf8.encode('$text\n\n')))
    .headers;

void main() {
  group('List-Unsubscribe', () {
    test('links in order, folded, with comments', () {
      final h = ListUnsubscribe.parse(
        _headers(
          'List-Unsubscribe: (web) <https://x.example/u/\n'
          ' abc>, <mailto:u@x.example?subject=stop> , <ftp://x.example/>\n'
          'List-Unsubscribe-Post: List-Unsubscribe=One-Click',
        ),
      );
      expect(h.links.map((u) => u.toString()), [
        'https://x.example/u/abc',
        'mailto:u@x.example?subject=stop',
      ]);
      expect(h.oneClick, isTrue);
    });

    test('one-click needs the exact value', () {
      final h = ListUnsubscribe.parse(
        _headers(
          'List-Unsubscribe: <https://x.example/u>\n'
          'List-Unsubscribe-Post: List-Unsubscribe=Yes',
        ),
      );
      expect(h.oneClick, isFalse);
    });

    test('hostile headers are bounded', () {
      final many = List.generate(50, (i) => '<https://x.example/$i>').join(',');
      final h = ListUnsubscribe.parse(_headers('List-Unsubscribe: $many'));
      expect(h.links, hasLength(ListUnsubscribe.maxLinks));
      expect(
        ListUnsubscribe.parse(_headers('List-Unsubscribe: <<>>')).isEmpty,
        isTrue,
      );
    });
  });

  group('DKIM-Signature', () {
    test('reads domain, selector and signed headers', () {
      final s = DkimSignature.parse(
        'v=1; a=rsa-sha256; d=Shop.Example; s=Mail;\n'
        ' h=From : To:List-Unsubscribe:\n list-unsubscribe-post; bh=x; b=y',
      )!;
      expect(s.domain, 'shop.example');
      expect(s.selector, 'mail');
      expect(
        s.signedHeaders,
        containsAll([
          'from',
          'to',
          'list-unsubscribe',
          'list-unsubscribe-post',
        ]),
      );
      expect(DkimSignature.parse('v=1; s=x'), isNull);
    });
  });

  group('mailto', () {
    test('one recipient, subject and body only', () {
      final r = MailtoRequest.parse(
        Uri.parse(
          'mailto:leave@x.example,boss@corp.example?subject=Stop%0D%0ABcc:%20a@b.c'
          '&body=please&cc=other@x.example&bcc=spy@x.example',
        ),
      )!;
      expect(r.address, 'leave@x.example');
      expect(r.subject, 'Stop Bcc: a@b.c', reason: 'no header injection');
      expect(r.body, 'please');
    });

    test('junk is refused', () {
      for (final s in [
        'mailto:',
        'mailto:not-an-address',
        'mailto:a b@x.example',
        'https://x.example',
      ]) {
        expect(MailtoRequest.parse(Uri.parse(s)), isNull, reason: s);
      }
    });
  });

  group('planner', () {
    test('verified one-click first, then email, then the web page', () {
      final plan = _plan(_fixture('newsletters/one-click-unsubscribe.eml'));
      expect(plan.listName, 'Shop Weekly');
      expect(plan.methods, hasLength(3));
      final oneClick = plan.methods[0] as OneClickMethod;
      expect(
        oneClick.url.toString(),
        'https://shop.example/unsub/abc123?u=alice',
      );
      final email = plan.methods[1] as EmailMethod;
      expect(email.request.address, 'unsubscribe@shop.example');
      expect(email.request.subject, 'unsubscribe-abc123');
      expect(plan.methods[2], isA<WebPageMethod>());
      expect(plan.after(oneClick), plan.methods.sublist(1));
    });

    test('no one-click when the signature failed', () {
      final plan = _plan(_fixture('newsletters/one-click-dkim-fail.eml'));
      expect(plan.methods.first, isA<EmailMethod>());
      expect(plan.methods.whereType<OneClickMethod>(), isEmpty);
    });

    test('no one-click before the server is known', () {
      final plan = _plan(
        _fixture('newsletters/one-click-unsubscribe.eml'),
        const TrustContext(),
      );
      expect(plan.methods.first, isA<EmailMethod>());
    });

    test('no one-click when the signature leaves out the headers', () {
      final plan = _plan(
        _mail('''
Authentication-Results: mail.citusmail.test; dkim=pass header.d=shop.example header.s=mail
DKIM-Signature: v=1; d=shop.example; s=mail; h=from:to:subject; b=x
From: Shop <news@shop.example>
List-Unsubscribe: <https://shop.example/u>
List-Unsubscribe-Post: List-Unsubscribe=One-Click'''),
      );
      expect(plan.methods.single, isA<WebPageMethod>());
    });

    test('a signature from another domain than the one verified', () {
      final plan = _plan(
        _mail('''
Authentication-Results: mail.citusmail.test; dkim=pass header.d=good.example
DKIM-Signature: v=1; d=evil.example; s=mail; h=list-unsubscribe:list-unsubscribe-post; b=x
From: Shop <news@shop.example>
List-Unsubscribe: <https://shop.example/u>
List-Unsubscribe-Post: List-Unsubscribe=One-Click'''),
      );
      expect(plan.methods.whereType<OneClickMethod>(), isEmpty);
    });

    test('mailto only, web page only, and none', () {
      final mailto = _plan(_fixture('newsletters/mailto-only-unsubscribe.eml'));
      expect(
        (mailto.methods.single as EmailMethod).request.address,
        'leave-123@lists.club.example',
      );
      expect(mailto.listName, 'Book Club', reason: 'List-Id has no name');

      final web = _plan(_fixture('newsletters/web-link-only-unsubscribe.eml'));
      expect(web.methods.single, isA<WebPageMethod>());

      final none = _plan(_fixture('newsletters/body-link-only.eml'));
      expect(none.available, isFalse);
      expect(none.refusal, UnsubscribeRefusal.none);
    });

    test('never for mail that looks like a scam', () {
      final plan = _plan(
        _mail('''
From: PayPal <service@paypal-security.example>
List-Unsubscribe: <mailto:u@paypal-security.example>'''),
      );
      expect(plan.available, isFalse);
      expect(plan.refusal, UnsubscribeRefusal.suspicious);
      expect(plan.reason, contains('may be a scam'));
    });

    test('an unverified sender (e.g. forwarded mail): offered, with a '
        'warning', () {
      final plan = _plan(
        _mail('''
Authentication-Results: mail.citusmail.test; dmarc=fail header.from=openrouter.ai
From: OpenRouter Team <welcome@openrouter.ai>
List-Unsubscribe: <https://openrouter.ai/unsubscribe?u=1>'''),
      );
      expect(plan.methods.single, isA<WebPageMethod>());
      expect(plan.warnings.single, contains('couldn\'t verify the sender'));
    });

    test('unsubscribe addresses get the phishing checks', () {
      // A lookalike page is left out; the email address still works.
      final mixed = _plan(
        _mail('''
From: Shop <news@shop.example>
List-Unsubscribe: <https://paypa1.com/u>, <mailto:leave@shop.example>'''),
      );
      expect(mixed.methods.single, isA<EmailMethod>());

      final unsafe = _plan(
        _mail('''
From: Shop <news@shop.example>
List-Unsubscribe: <https://user@evil.example/u>'''),
      );
      expect(unsafe.refusal, UnsubscribeRefusal.unsafeLink);
      expect(unsafe.reason, contains('isn\'t safe'));

      final numeric = _plan(
        _mail('''
From: Shop <news@shop.example>
List-Unsubscribe: <http://203.0.113.9/u>'''),
      );
      expect(numeric.methods.single, isA<WebPageMethod>());
      expect(numeric.warnings.first, contains('numeric'));
    });

    test('for an unverified sender, another domain is pointed out', () {
      final plan = _plan(
        _mail('''
Authentication-Results: mail.citusmail.test; dmarc=fail header.from=openrouter.ai
From: OpenRouter Team <welcome@openrouter.ai>
List-Unsubscribe: <https://unsub.mailer.example/x>'''),
      );
      expect(
        plan.warnings,
        contains(contains('at mailer.example, not at the sender')),
      );
      // A verified sender may use any mailing service without remark.
      final verified = _plan(
        _mail('''
Authentication-Results: mail.citusmail.test; dmarc=pass header.from=openrouter.ai
From: OpenRouter Team <welcome@openrouter.ai>
List-Unsubscribe: <https://unsub.mailer.example/x>'''),
      );
      expect(verified.warnings, isEmpty);
    });
  });

  group('one-click', () {
    late ServerSocket server;
    final requests = <String>[];

    Future<OneClickResult> send(String reply) async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) {
        final got = BytesBuilder();
        client.listen((data) {
          got.add(data);
          final text = latin1.decode(got.toBytes());
          if (!text.endsWith('One-Click')) return;
          requests.add(text);
          client
            ..write(reply)
            ..close();
        });
      });
      final web = WebClient(
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        connector: (host, address, port, timeout) => MailSocket.connect(
          ServerEndpoint(
            host,
            server.port,
            ConnectionSecurity.startTls,
            connectAddress: '127.0.0.1',
          ),
        ),
      );
      final result = await OneClickUnsubscriber(web)
          .unsubscribe(Uri.parse('https://shop.example.com/unsub/abc'));
      await server.close();
      return result;
    }

    setUp(requests.clear);

    test('posts the RFC 8058 body', () async {
      expect(await send('HTTP/1.1 200 OK\r\n\r\n'), isA<OneClickDone>());
      expect(requests.single, startsWith('POST /unsub/abc HTTP/1.1\r\n'));
      expect(
        requests.single,
        contains('Content-Type: application/x-www-form-urlencoded\r\n'),
      );
      expect(requests.single, endsWith('\r\n\r\nList-Unsubscribe=One-Click'));
    });

    test('a refusal or redirect is a failure the user can act on', () async {
      final refused = await send('HTTP/1.1 500 Oops\r\n\r\n');
      expect((refused as OneClickFailed).reason, contains('error 500'));
      final moved = await send(
        'HTTP/1.1 303 See Other\r\nLocation: /x\r\n\r\n',
      );
      expect((moved as OneClickFailed).reason, contains('another page'));
    });

    test('unsafe addresses fail without a request', () async {
      final result = await OneClickUnsubscriber(WebClient())
          .unsubscribe(Uri.parse('https://192.168.1.1/u'));
      expect((result as OneClickFailed).reason, contains('isn\'t safe'));
    });
  });
}
