// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A character set that can turn bytes into text.
///
/// Decoding never throws: bytes that are not valid in the charset become
/// U+FFFD (the replacement character), as the WHATWG Encoding Standard
/// specifies. Mail is untrusted input, so a broken message must still show.
abstract base class Charset {
  const Charset(this.name);

  /// The WHATWG encoding name, lowercase (e.g. `utf-8`, `shift_jis`).
  final String name;

  /// Decodes `bytes[start, end)`.
  String decode(List<int> bytes, [int start = 0, int? end]);

  @override
  String toString() => 'Charset($name)';
}

/// Shared plumbing for charsets that decode one byte at a time.
abstract base class ByteDecoderCharset extends Charset {
  const ByteDecoderCharset(super.name);

  static const int replacement = 0xFFFD;

  @override
  String decode(List<int> bytes, [int start = 0, int? end]) {
    final stop = RangeError.checkValidRange(start, end, bytes.length);
    final out = StringBuffer();
    decodeInto(bytes, start, stop, out);
    return out.toString();
  }

  /// Decodes `bytes[start, end)` into [out].
  void decodeInto(List<int> bytes, int start, int end, StringBuffer out);

  static bool isAscii(int byte) => byte < 0x80;
}
