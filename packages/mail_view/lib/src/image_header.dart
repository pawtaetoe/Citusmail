// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// What an image file says about itself.
typedef ImageInfo = ({String mimeType, int width, int height});

/// Reads the type and pixel size of PNG, JPEG, GIF and WebP images from
/// their first bytes, without decoding them.
///
/// Used before an image is handed to the platform decoder: a few kilobytes
/// can claim to be 60000 x 60000 pixels and need gigabytes once decoded
/// (a "decompression bomb"), and a file can claim one type and be another.
abstract final class ImageHeader {
  /// Largest side accepted.
  static const maxSide = 16384;

  /// Largest area accepted (40 megapixels: about 160 MB decoded).
  static const maxPixels = 40 * 1000 * 1000;

  /// The image's type and size, or null if it is not a PNG, JPEG, GIF or
  /// WebP image whose header can be read.
  static ImageInfo? read(Uint8List b) {
    if (_starts(b, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      // IHDR is the first chunk: length, "IHDR", width, height.
      if (b.length < 24 || !_ascii(b, 12, 'IHDR')) return null;
      return _info('image/png', _be32(b, 16), _be32(b, 20));
    }
    if (_ascii(b, 0, 'GIF87a') || _ascii(b, 0, 'GIF89a')) {
      if (b.length < 10) return null;
      return _info('image/gif', b[6] | b[7] << 8, b[8] | b[9] << 8);
    }
    if (_starts(b, const [0xFF, 0xD8])) return _jpeg(b);
    if (_ascii(b, 0, 'RIFF') && _ascii(b, 8, 'WEBP')) return _webp(b);
    return null;
  }

  /// Whether [bytes] are an image of a size safe to decode, of one of
  /// [types] (all four by default).
  static bool isSafe(Uint8List bytes, {Set<String>? types}) {
    final info = read(bytes);
    return info != null && (types == null || types.contains(info.mimeType));
  }

  static ImageInfo? _info(String type, int width, int height) {
    if (width <= 0 || height <= 0) return null;
    if (width > maxSide || height > maxSide) return null;
    if (width * height > maxPixels) return null;
    return (mimeType: type, width: width, height: height);
  }

  /// Walks the segments to the first frame header (SOFn).
  static ImageInfo? _jpeg(Uint8List b) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++; // fill byte
        continue;
      }
      // Markers without a length.
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final length = b[i + 2] << 8 | b[i + 3];
      if (length < 2) return null;
      final isFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isFrame) {
        return _info(
          'image/jpeg',
          b[i + 7] << 8 | b[i + 8],
          b[i + 5] << 8 | b[i + 6],
        );
      }
      if (marker == 0xD9 || marker == 0xDA) return null; // no frame header
      i += 2 + length;
    }
    return null;
  }

  static ImageInfo? _webp(Uint8List b) {
    if (b.length < 25) return null;
    if (_ascii(b, 12, 'VP8X')) {
      if (b.length < 30) return null;
      final w = (b[24] | b[25] << 8 | b[26] << 16) + 1;
      final h = (b[27] | b[28] << 8 | b[29] << 16) + 1;
      return _info('image/webp', w, h);
    }
    if (_ascii(b, 12, 'VP8L')) {
      if (b[20] != 0x2F) return null;
      final bits = b[21] | b[22] << 8 | b[23] << 16 | b[24] << 24;
      return _info(
        'image/webp',
        (bits & 0x3FFF) + 1,
        (bits >> 14 & 0x3FFF) + 1,
      );
    }
    if (_ascii(b, 12, 'VP8 ')) {
      if (b.length < 30) return null;
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      return _info(
        'image/webp',
        (b[26] | b[27] << 8) & 0x3FFF,
        (b[28] | b[29] << 8) & 0x3FFF,
      );
    }
    return null;
  }

  static bool _starts(Uint8List b, List<int> prefix) {
    if (b.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (b[i] != prefix[i]) return false;
    }
    return true;
  }

  static bool _ascii(Uint8List b, int at, String text) {
    if (b.length < at + text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[at + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _be32(Uint8List b, int at) =>
      b[at] << 24 | b[at + 1] << 16 | b[at + 2] << 8 | b[at + 3];
}
