// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

Uint8List _png(int w, int h) => _bytes([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  0,
  0,
  13,
  ...ascii.encode('IHDR'),
  w >> 24 & 255,
  w >> 16 & 255,
  w >> 8 & 255,
  w & 255,
  h >> 24 & 255,
  h >> 16 & 255,
  h >> 8 & 255,
  h & 255,
  8,
  6,
  0,
  0,
  0,
]);

void main() {
  group('ImageHeader', () {
    test('PNG', () {
      final info = ImageHeader.read(_png(640, 480))!;
      expect(info.mimeType, 'image/png');
      expect((info.width, info.height), (640, 480));
    });

    test('GIF', () {
      final gif = _bytes([
        ...ascii.encode('GIF89a'),
        0x20,
        0x03,
        0x58,
        0x02,
        0,
        0,
      ]);
      expect(ImageHeader.read(gif), (
        mimeType: 'image/gif',
        width: 800,
        height: 600,
      ));
    });

    test('JPEG: skips segments to the frame header', () {
      final jpeg = _bytes([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, // APP0, 2 bytes of data
        0xFF, 0xFF, // fill
        0xFF,
        0xC2,
        0x00,
        0x11,
        0x08,
        0x01,
        0x00,
        0x02,
        0x00,
        3,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(ImageHeader.read(jpeg), (
        mimeType: 'image/jpeg',
        width: 512,
        height: 256,
      ));
    });

    test('WebP: VP8X, VP8L and VP8', () {
      List<int> riff(String chunk, List<int> data) => [
        ...ascii.encode('RIFF'),
        0,
        0,
        0,
        0,
        ...ascii.encode('WEBP'),
        ...ascii.encode(chunk),
        0,
        0,
        0,
        0,
        ...data,
      ];
      final x = _bytes(riff('VP8X', [0, 0, 0, 0, 99, 0, 0, 49, 0, 0]));
      expect(ImageHeader.read(x), (
        mimeType: 'image/webp',
        width: 100,
        height: 50,
      ));
      // 14-bit width-1 = 99, height-1 = 49.
      const bits = 99 | 49 << 14;
      final l = _bytes(
        riff('VP8L', [
          0x2F,
          bits & 255,
          bits >> 8 & 255,
          bits >> 16 & 255,
          bits >> 24 & 255,
          0,
          0,
          0,
          0,
        ]),
      );
      expect(ImageHeader.read(l), (
        mimeType: 'image/webp',
        width: 100,
        height: 50,
      ));
      final lossy = _bytes(
        riff('VP8 ', [0, 0, 0, 0x9D, 0x01, 0x2A, 100, 0, 50, 0]),
      );
      expect(ImageHeader.read(lossy), (
        mimeType: 'image/webp',
        width: 100,
        height: 50,
      ));
    });

    test('decompression bombs, zero sizes and other formats are refused', () {
      expect(ImageHeader.read(_png(60000, 60000)), isNull);
      expect(ImageHeader.read(_png(10000, 10000)), isNull, reason: '100 MP');
      expect(ImageHeader.read(_png(16384, 100)), isNotNull);
      expect(ImageHeader.read(_png(0, 10)), isNull);
      expect(
        ImageHeader.read(_bytes(utf8.encode('<svg xmlns="..."/>'))),
        isNull,
      );
      expect(
        ImageHeader.read(_bytes(ascii.encode('BM'))),
        isNull,
        reason: 'BMP',
      );
      expect(ImageHeader.read(_bytes([0xFF, 0xD8, 0xFF, 0xDA, 0, 2])), isNull);
      expect(ImageHeader.read(Uint8List(0)), isNull);
      expect(
        ImageHeader.read(_png(1, 1).sublist(0, 20)),
        isNull,
        reason: 'cut',
      );
      expect(ImageHeader.isSafe(_png(10, 10), types: {'image/gif'}), isFalse);
    });
  });

  group('TrackingPixels', () {
    bool tracker(String url, {double? w, double? h, String? style}) =>
        TrackingPixels.isTracker(
          Uri.parse(url),
          width: w,
          height: h,
          style: style,
        );

    test('tiny, invisible, known hosts and tracking paths', () {
      expect(tracker('https://cdn.example/a.png', w: 1, h: 1), isTrue);
      expect(tracker('https://cdn.example/a.png', h: 0), isTrue);
      expect(tracker('https://cdn.example/a.png', style: 'width:0'), isTrue);
      expect(
        tracker('https://cdn.example/a.png', style: 'opacity: 0;'),
        isTrue,
      );
      expect(tracker('https://x.awstrack.me/I0/abc'), isTrue);
      expect(tracker('https://list.example/track/open.php?u=1'), isTrue);
      expect(tracker('https://u1.ct.sendgrid.net/wf/open?upn=x'), isTrue);
      expect(tracker('https://mail.example/o/eJxVkMtu'), isTrue);
    });

    test('ordinary images are not trackers', () {
      expect(
        tracker('https://cdn.example/banner.jpg', w: 600, h: 200),
        isFalse,
      );
      expect(
        tracker('https://cdn.example/a.png', style: 'width:100px'),
        isFalse,
      );
      expect(tracker('https://cdn.example/open-house.jpg'), isFalse);
      expect(tracker('https://cdn.example/pixelart/cat.png'), isFalse);
    });
  });
}
