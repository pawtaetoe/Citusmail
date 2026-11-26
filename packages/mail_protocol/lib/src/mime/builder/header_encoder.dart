// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import '../address.dart';
import 'outgoing_message.dart';

/// Writes header fields: RFC 2047 encoding for non-ASCII text, quoting for
/// display names, and folding to 78 characters.
///
/// Nothing the caller passes can add a header line: control characters in
/// text become spaces, and addresses containing them are rejected.
final class HeaderEncoder {
  const HeaderEncoder();

  static const int foldWidth = 78;

  /// Encoded words must be at most 75 characters (RFC 2047 2). With the
  /// "=?UTF-8?B?" + "?=" overhead that leaves 60 base64 characters, which
  /// hold 45 bytes.
  static const int _maxBytesPerWord = 45;

  static final _atext = RegExp(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~ -]+$");
  static final _localPart = RegExp(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$");
  static final _domain = RegExp(
    r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
  );

  /// `Name: value` for free text such as Subject.
  String unstructured(String name, String value) {
    final clean = sanitizeText(value).trim();
    return fold(
      name,
      _needsEncoding(clean) ? encodeWords(clean) : _splitSpaces(clean),
    );
  }

  /// `Name: a, b, c` for an address list.
  String addressList(String name, List<MailAddress> addresses) {
    final tokens = <String>[];
    for (var i = 0; i < addresses.length; i++) {
      final mailbox = mailboxTokens(addresses[i]);
      if (i < addresses.length - 1) mailbox[mailbox.length - 1] += ',';
      tokens.addAll(mailbox);
    }
    return fold(name, tokens);
  }

  /// `Name: <id1> <id2>` for Message-ID, In-Reply-To and References.
  String messageIds(String name, List<String> ids) {
    for (final id in ids) {
      if (!RegExp(r'^[\x21-\x7E]+$').hasMatch(id) ||
          id.contains('<') ||
          id.contains('>')) {
        throw MessageBuildException('invalid message ID');
      }
    }
    return fold(name, [for (final id in ids) '<$id>']);
  }

  /// A mailbox as foldable tokens: display name words, then `<address>`.
  List<String> mailboxTokens(MailAddress address) {
    final addr = '<${validateAddress(address)}>';
    final name = sanitizeText(address.displayName ?? '').trim();
    if (name.isEmpty) return [addr];
    if (_needsEncoding(name)) return [...encodeWords(name), addr];
    if (_atext.hasMatch(name)) return [..._splitSpaces(name), addr];
    return [_quote(name), addr];
  }

  /// Checks an address and returns `local@domain`. Throws on anything that
  /// could break the header or is not a deliverable address.
  String validateAddress(MailAddress address) {
    final local = address.localPart;
    if (_hasControl(local) || _hasControl(address.domain)) {
      throw const MessageBuildException('address contains control characters');
    }
    final domain = asciiDomain(address.domain);
    if (!_localPart.hasMatch(local) ||
        local.startsWith('.') ||
        local.endsWith('.') ||
        local.contains('..')) {
      // Quoted local parts and SMTPUTF8 local parts are not supported yet.
      throw MessageBuildException(
        'unsupported address local part: ${address.address}',
      );
    }
    if (!_domain.hasMatch(domain) || domain.length > 253) {
      throw MessageBuildException('invalid address domain: ${address.address}');
    }
    return '$local@$domain';
  }

  /// [domain] as DNS and SMTP need it: each label with letters beyond
  /// ASCII in its Punycode form (`münchen.de` is `xn--mnchen-3ya.de`,
  /// RFC 3490 and 3492), lower case.
  static String asciiDomain(String domain) {
    if (domain.runes.every((r) => r < 0x80)) return domain;
    return domain
        .replaceAll(RegExp('[\u3002\uFF0E\uFF61]'), '.')
        .split('.')
        .map((label) {
          final lower = label.toLowerCase();
          return lower.runes.every((r) => r < 0x80)
              ? lower
              : 'xn--${_punycode(lower)}';
        })
        .join('.');
  }

  /// The Punycode encoding of [label] (RFC 3492 6.3).
  static String _punycode(String label) {
    const base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700;
    final input = label.runes.toList();
    final out = StringBuffer();
    for (final c in input) {
      if (c < 0x80) out.writeCharCode(c);
    }
    final basic = out.length;
    if (basic > 0) out.write('-');
    int adapt(int delta, int points, {required bool first}) {
      var d = first ? delta ~/ damp : delta ~/ 2;
      d += d ~/ points;
      var k = 0;
      while (d > ((base - tMin) * tMax) ~/ 2) {
        d ~/= base - tMin;
        k += base;
      }
      return k + ((base - tMin + 1) * d) ~/ (d + skew);
    }

    // 0-25 are a-z, 26-35 are 0-9.
    String symbol(int d) => String.fromCharCode(d < 26 ? 0x61 + d : 0x16 + d);
    var n = 0x80, delta = 0, bias = 72, handled = basic;
    while (handled < input.length) {
      final next = input.where((c) => c >= n).reduce((a, b) => a < b ? a : b);
      delta += (next - n) * (handled + 1);
      n = next;
      for (final c in input) {
        if (c < n) delta++;
        if (c != n) continue;
        var q = delta;
        for (var k = base; ; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          out.write(symbol(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        out.write(symbol(q));
        bias = adapt(delta, handled + 1, first: handled == basic);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return out.toString();
  }

  /// RFC 2047 "B" encoded words in UTF-8, split on whole characters.
  List<String> encodeWords(String text) {
    final words = <String>[];
    final chunk = StringBuffer();
    var chunkBytes = 0;
    void flush() {
      if (chunk.isEmpty) return;
      words.add('=?UTF-8?B?${base64.encode(utf8.encode(chunk.toString()))}?=');
      chunk.clear();
      chunkBytes = 0;
    }

    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (chunkBytes + size > _maxBytesPerWord) flush();
      chunk.write(char);
      chunkBytes += size;
    }
    flush();
    return words;
  }

  /// Joins tokens after `Name:` with single spaces, starting a new line
  /// (CRLF + space) whenever a line would exceed 78 characters.
  String fold(String name, List<String> tokens) {
    if (!RegExp(r'^[!-9;-~]+$').hasMatch(name)) {
      throw MessageBuildException('invalid header name: $name');
    }
    final out = StringBuffer('$name:');
    var lineLength = out.length;
    for (final token in tokens) {
      // Fold before a token that would overflow, even right after "Name:"
      // (folding there is valid FWS), but never twice in a row.
      // An empty token (from a double space) is never folded before: a line
      // of only whitespace is forbidden (RFC 5322 3.2.2).
      if (token.isNotEmpty &&
          lineLength + 1 + token.length > foldWidth &&
          lineLength > 0) {
        out.write('\r\n');
        lineLength = 0;
      }
      out
        ..write(' ')
        ..write(token);
      lineLength += 1 + token.length;
    }
    out.write('\r\n');
    return out.toString();
  }

  /// Replaces control characters (including CR and LF) with spaces.
  static String sanitizeText(String text) =>
      text.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');

  static bool _hasControl(String s) => RegExp(r'[\x00-\x1F\x7F]').hasMatch(s);

  /// Non-ASCII text, or text a decoder might mistake for an encoded word.
  static bool _needsEncoding(String text) =>
      text.runes.any((r) => r > 0x7E) || text.contains('=?');

  /// Splits at single spaces, keeping empty tokens, so joining with single
  /// spaces (and unfolding) restores the exact text.
  static List<String> _splitSpaces(String text) =>
      text.isEmpty ? const [] : text.split(' ');

  static String _quote(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
