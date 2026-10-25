// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:citusmail/src/services/remote_images.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_web.dart';

final _png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  late FakeWeb web;
  setUp(() async => web = await FakeWeb.start());
  tearDown(() => web.close());

  Uri url(String path) => Uri.parse('https://cdn.example.com$path');

  test('loads once, even when asked twice at the same time', () async {
    web.serve('GET /a.png', _png);
    final images = RemoteImages(web.client);
    final both = await Future.wait([
      images.load(url('/a.png')),
      images.load(url('/a.png')),
    ]);
    expect(both.every((b) => b?.length == _png.length), isTrue);
    expect(await images.load(url('/a.png')), isNotNull, reason: 'cached');
    expect(web.requests, ['cdn.example.com GET /a.png']);
  });

  test('not an image, missing, or a tracker: null', () async {
    web.serve('GET /fake.png', utf8.encode('<svg/>'));
    web.routes['GET /redirect.png'] = latin1.encode(
      'HTTP/1.1 302 Found\r\nLocation: https://x.awstrack.me/I0/a\r\n'
      'Content-Length: 0\r\n\r\n',
    );
    final images = RemoteImages(web.client);
    expect(await images.load(url('/fake.png')), isNull);
    expect(await images.load(url('/missing.png')), isNull);
    expect(await images.load(url('/redirect.png')), isNull);
    expect(
      web.requests.where((r) => r.contains('awstrack')),
      isEmpty,
      reason: 'the tracker behind the redirect is never contacted',
    );
  });

  test('at most a few downloads at once', () async {
    for (var i = 0; i < 10; i++) {
      web.serve('GET /$i.png', _png);
    }
    final images = RemoteImages(web.client, maxParallel: 2);
    final all = await Future.wait([
      for (var i = 0; i < 10; i++) images.load(url('/$i.png')),
    ]);
    expect(all.every((b) => b != null), isTrue);
    expect(web.requests, hasLength(10));
  });
}
