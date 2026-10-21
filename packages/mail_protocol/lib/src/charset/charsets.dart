// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'charset.dart';
import 'chinese_korean_charsets.dart';
import 'japanese_charsets.dart';
import 'simple_charsets.dart';
import 'whatwg_data.g.dart';

/// Finds charsets by the labels used in mail (`charset=` parameters and
/// RFC 2047 encoded words), using the WHATWG label list.
///
/// Note that WHATWG maps `iso-8859-1` and `us-ascii` to windows-1252, a
/// superset. Mail labelled Latin-1 often really is Windows-1252 (curly
/// quotes, euro sign), so this matches what browsers and Thunderbird show.
abstract final class Charsets {
  static const Utf8Charset utf8 = Utf8Charset();

  static final Charset windows1252 = forName('windows-1252')!;

  static final Map<String, Charset> _byName = {};

  /// The charset for a label such as `"UTF-8"`, `"latin1"` or `"x-sjis"`,
  /// or null if the label is unknown.
  static Charset? forLabel(String label) {
    final name = whatwgLabels[_normalize(label)];
    return name == null ? null : forName(name);
  }

  /// The charset with a WHATWG encoding [name], or null.
  static Charset? forName(String name) {
    final cached = _byName[name];
    if (cached != null) return cached;
    final created = _create(name);
    if (created != null) _byName[name] = created;
    return created;
  }

  static Charset? _create(String name) => switch (name) {
    'utf-8' => utf8,
    'utf-16le' => const Utf16Charset.littleEndian(),
    'utf-16be' => const Utf16Charset.bigEndian(),
    'gbk' || 'gb18030' => Gb18030Charset(name),
    'big5' => Big5Charset(),
    'euc-kr' => EucKrCharset(),
    'shift_jis' => ShiftJisCharset(),
    'euc-jp' => EucJpCharset(),
    'iso-2022-jp' => Iso2022JpCharset(),
    'replacement' => const ReplacementCharset(),
    'x-user-defined' => const UserDefinedCharset(),
    // ISO-8859-8-I differs only in text direction, not in bytes.
    'iso-8859-8-i' => SingleByteCharset(name, 'iso-8859-8'),
    _ when whatwgLabels.containsValue(name) => SingleByteCharset(name, name),
    _ => null,
  };

  /// WHATWG label matching: strip ASCII whitespace, compare lowercase.
  static String _normalize(String label) =>
      label.trim().replaceAll(RegExp('^["\']|["\']\$'), '').toLowerCase();
}
