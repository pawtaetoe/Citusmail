// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'generated/public_suffixes.g.dart';

/// Domain names as people see them: lower case, international labels
/// decoded (`xn--pple-43d` becomes `аpple` with a Cyrillic "а"), and the
/// registrable part (`paypal.co.uk` of `secure.paypal.co.uk`) from the
/// Public Suffix List.
abstract final class Domains {
  /// Lower case, without a trailing dot, with `xn--` labels decoded; null
  /// for something that is not a host name.
  static String? normalize(String host) {
    var h = host.trim();
    if (h.startsWith('[') && h.endsWith(']')) return h.toLowerCase(); // IPv6
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.isEmpty || h.length > 253) return null;
    final labels = <String>[];
    for (final raw in h.split('.')) {
      final label = _asciiLower(raw);
      if (label.isEmpty || label.length > 63) return null;
      if (label.startsWith('xn--')) {
        final decoded = Punycode.decode(label.substring(4));
        if (decoded == null) return null;
        labels.add(decoded.toLowerCase());
      } else {
        labels.add(label.toLowerCase());
      }
    }
    return labels.join('.');
  }

  static bool isIpAddress(String host) {
    final h = host.trim();
    if (h.startsWith('[') || h.contains(':')) return true; // IPv6
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h) ||
        RegExp(r'^\d+$').hasMatch(h) || // 3232235777 style
        RegExp(r'^0x[0-9a-f]+$', caseSensitive: false).hasMatch(h);
  }

  /// The registrable domain ("eTLD+1"), or null if [host] is a public
  /// suffix itself, an IP address or invalid.
  static String? registrable(String host) {
    if (isIpAddress(host)) return null;
    final normalized = normalize(host);
    if (normalized == null) return null;
    final labels = normalized.split('.');
    final suffix = _publicSuffixLength(labels);
    if (labels.length <= suffix) return null;
    return labels.sublist(labels.length - suffix - 1).join('.');
  }

  /// How many labels at the end form the public suffix (PSL algorithm:
  /// the longest matching rule wins; exceptions beat wildcards; unknown
  /// endings count as one label).
  static int _publicSuffixLength(List<String> labels) {
    for (var i = 0; i < labels.length; i++) {
      final candidate = labels.sublist(i).join('.');
      if (publicSuffixRules.contains('!$candidate')) {
        return labels.length - i - 1;
      }
      if (publicSuffixRules.contains(candidate)) return labels.length - i;
      if (i + 1 < labels.length &&
          publicSuffixRules.contains('*.${labels.sublist(i + 1).join('.')}')) {
        return labels.length - i;
      }
    }
    return 1;
  }

  static String _asciiLower(String s) => String.fromCharCodes([
    for (final c in s.codeUnits) c >= 0x41 && c <= 0x5A ? c + 0x20 : c,
  ]);
}

/// Punycode (RFC 3492) decoding, for `xn--` labels.
abstract final class Punycode {
  static const _base = 36, _tMin = 1, _tMax = 26, _skew = 38, _damp = 700;

  /// The Unicode label, or null if [input] is not valid Punycode.
  static String? decode(String input) {
    if (input.length > 63) return null;
    var n = 128, i = 0, bias = 72;
    final output = <int>[];
    final b = input.lastIndexOf('-');
    if (b > 0) {
      for (final c in input.substring(0, b).codeUnits) {
        if (c >= 0x80) return null;
        output.add(c);
      }
    }
    var pos = b > 0 ? b + 1 : 0;
    while (pos < input.length) {
      final oldI = i;
      var w = 1;
      for (var k = _base; ; k += _base) {
        if (pos >= input.length) return null;
        final digit = _digit(input.codeUnitAt(pos++));
        if (digit < 0) return null;
        if (digit > (0x7FFFFFFF - i) ~/ w) return null; // overflow
        i += digit * w;
        final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
        if (digit < t) break;
        if (w > 0x7FFFFFFF ~/ (_base - t)) return null;
        w *= _base - t;
      }
      final length = output.length + 1;
      bias = _adapt(i - oldI, length, first: oldI == 0);
      if (i ~/ length > 0x10FFFF - n) return null;
      n += i ~/ length;
      i %= length;
      if (n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) return null;
      output.insert(i, n);
      i++;
    }
    return String.fromCharCodes(output);
  }

  static int _digit(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 22; // 0-9 -> 26-35
    if (c >= 0x41 && c <= 0x5A) return c - 0x41; // A-Z
    if (c >= 0x61 && c <= 0x7A) return c - 0x61; // a-z
    return -1;
  }

  static int _adapt(int delta, int length, {required bool first}) {
    var d = first ? delta ~/ _damp : delta ~/ 2;
    d += d ~/ length;
    var k = 0;
    while (d > ((_base - _tMin) * _tMax) ~/ 2) {
      d ~/= _base - _tMin;
      k += _base;
    }
    return k + ((_base - _tMin + 1) * d) ~/ (d + _skew);
  }
}

/// Letters from other alphabets that look like Latin ones, used to spot
/// lookalike names such as `аpple` (Cyrillic "а").
abstract final class Lookalikes {
  /// Cyrillic and Greek letters drawn like Latin letters, and digits that
  /// pass for letters.
  static const _toLatin = {
    // Cyrillic
    'а': 'a', 'в': 'b', 'с': 'c', 'ԁ': 'd', 'е': 'e', 'һ': 'h', 'і': 'i',
    'ј': 'j', 'к': 'k', 'ӏ': 'l', 'м': 'm', 'н': 'h', 'о': 'o', 'р': 'p',
    'ԛ': 'q', 'г': 'r', 'ѕ': 's', 'т': 't', 'ս': 'u', 'ν': 'v', 'ԝ': 'w',
    'х': 'x', 'у': 'y', 'ү': 'y', 'ɡ': 'g',
    // Greek
    'α': 'a', 'β': 'b', 'ε': 'e', 'ι': 'i', 'κ': 'k', 'ο': 'o', 'ρ': 'p',
    'τ': 't', 'υ': 'u', 'χ': 'x', 'γ': 'y',
  };

  static const _digits = {'0': 'o', '1': 'l', '3': 'e', '5': 's'};

  /// [label] with lookalike letters replaced by the Latin ones they imitate
  /// (digits too when [digits] is set: `paypa1` -> `paypal`).
  static String skeleton(String label, {bool digits = false}) {
    final out = StringBuffer();
    for (final ch in label.split('')) {
      out.write(_toLatin[ch] ?? (digits ? _digits[ch] : null) ?? ch);
    }
    return out.toString().replaceAll('rn', 'm').replaceAll('vv', 'w');
  }

  /// Whether [label] mixes Latin with Cyrillic or Greek letters, or is made
  /// only of letters that imitate Latin ones: both are typical of
  /// lookalike domains, rare in genuine names.
  static bool isDeceptive(String label) {
    final scripts = <String>{};
    for (final rune in label.runes) {
      final s = _script(rune);
      if (s != null) scripts.add(s);
    }
    if (scripts.contains('latin') && scripts.length > 1) return true;
    if (scripts.length == 1 && !scripts.contains('latin')) {
      // Wholly Cyrillic/Greek, but every letter looks Latin.
      final skel = skeleton(label);
      return RegExp(r'^[a-z0-9-]+$').hasMatch(skel);
    }
    return false;
  }

  static String? _script(int rune) {
    if ((rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0xE0 && rune <= 0x24F) ||
        rune == 0x261) {
      return 'latin';
    }
    if (rune >= 0x400 && rune <= 0x52F) return 'cyrillic';
    if (rune >= 0x370 && rune <= 0x3FF) return 'greek';
    if (rune == 0x57D) return 'armenian';
    if (rune >= 0x30 && rune <= 0x39 || rune == 0x2D) return null;
    return rune < 0x80 ? null : 'other';
  }
}
