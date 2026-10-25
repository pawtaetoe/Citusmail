// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// URL canonicalization and lookup expressions as Google Safe Browsing
/// defines them ("URLs and Hashing", Update API v4), so the hashes the app
/// computes match the ones in Google's lists.
abstract final class SafeBrowsingUrl {
  /// The canonical form of [url] (`http://host/path?query`), or null if it
  /// has no usable host.
  static String? canonicalize(String url) {
    // Tab, CR and LF are removed; surrounding spaces too.
    var text = url.replaceAll(RegExp('[\t\r\n]'), '').trim();
    final hash = text.indexOf('#');
    if (hash >= 0) text = text.substring(0, hash);

    // Scheme: assumed http when missing.
    final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/').firstMatch(text);
    var schemeName = 'http';
    if (scheme != null) {
      schemeName = scheme.group(1)!.toLowerCase();
      text = text.substring(scheme.end);
    }

    // Host [:port] / path ? query.
    var slash = text.indexOf('/');
    final question = text.indexOf('?');
    if (question >= 0 && (slash < 0 || question < slash)) slash = question;
    var authority = slash < 0 ? text : text.substring(0, slash);
    var rest = slash < 0 ? '/' : text.substring(slash);
    if (rest.startsWith('?')) rest = '/$rest';
    final at = authority.lastIndexOf('@');
    if (at >= 0) authority = authority.substring(at + 1);
    final colon = authority.lastIndexOf(':');
    if (colon >= 0 && !authority.contains(']')) {
      authority = authority.substring(0, colon);
    }

    var host = _unescapeFully(authority);
    host = host.replaceAll(RegExp(r'^\.+|\.+$'), '');
    host = host.replaceAll(RegExp(r'\.{2,}'), '.');
    host = host.toLowerCase();
    if (host.isEmpty) return null;
    host = _ipv4(host) ?? host;

    final queryStart = rest.indexOf('?');
    var path = queryStart < 0 ? rest : rest.substring(0, queryStart);
    final query = queryStart < 0 ? null : rest.substring(queryStart + 1);
    path = _canonicalPath(_unescapeFully(path));

    final out = StringBuffer()
      ..write(schemeName)
      ..write('://')
      ..write(_escape(host))
      ..write(_escape(path));
    if (query != null) out.write('?${_escape(_unescapeFully(query))}');
    return out.toString();
  }

  /// The host-suffix / path-prefix combinations to look up for a
  /// canonical URL (without the scheme), at most 30.
  static List<String> expressions(String canonical) {
    final withoutScheme = canonical.substring(canonical.indexOf('://') + 3);
    final slash = withoutScheme.indexOf('/');
    final host = withoutScheme.substring(0, slash);
    final pathAndQuery = withoutScheme.substring(slash);

    final hosts = <String>[host];
    if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) {
      final parts = host.split('.');
      // The last five components, dropping the leading one each time,
      // down to two components.
      final start = parts.length > 5 ? parts.length - 5 : 1;
      for (var i = start; i <= parts.length - 2; i++) {
        final suffix = parts.sublist(i).join('.');
        if (suffix != host && !hosts.contains(suffix)) hosts.add(suffix);
      }
    }

    final q = pathAndQuery.indexOf('?');
    final path = q < 0 ? pathAndQuery : pathAndQuery.substring(0, q);
    final paths = <String>[pathAndQuery];
    if (q >= 0) paths.add(path);
    // "/", then "/a/", "/a/b/"... (at most four in all).
    final components = path.split('/').where((c) => c.isNotEmpty).toList();
    var prefix = '/';
    final prefixes = <String>[prefix];
    for (var i = 0; i < components.length - 1 && prefixes.length < 4; i++) {
      prefix = '$prefix${components[i]}/';
      prefixes.add(prefix);
    }
    for (final p in prefixes) {
      if (!paths.contains(p)) paths.add(p);
    }

    return [
      for (final h in hosts)
        for (final p in paths) '$h$p',
    ].take(30).toList();
  }

  /// SHA-256 of each expression of [url]; empty if it can't be checked.
  static List<Uint8List> hashes(String url) {
    final canonical = canonicalize(url);
    if (canonical == null) return const [];
    return [
      for (final e in expressions(canonical))
        Uint8List.fromList(sha256.convert(utf8.encode(e)).bytes),
    ];
  }

  /// Percent-decodes until nothing changes (at most 1024 rounds). Works
  /// on bytes, so the result is a "binary" string of code units < 256.
  static String _unescapeFully(String text) {
    var current = latin1.decode(utf8.encode(text), allowInvalid: true);
    for (var i = 0; i < 1024; i++) {
      final next = current.replaceAllMapped(
        RegExp('%([0-9A-Fa-f]{2})'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      );
      if (next == current) break;
      current = next;
    }
    return current;
  }

  /// Resolves `/./` and `/../`, and collapses repeated slashes.
  static String _canonicalPath(String path) {
    final segments = <String>[];
    final parts = path.split('/');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final last = i == parts.length - 1;
      if (part == '.' || (part.isEmpty && !last)) continue;
      if (part == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(part);
    }
    final joined = '/${segments.join('/')}';
    // A trailing "/." or "/.." means a directory: keep the slash.
    final trailing =
        path.endsWith('/.') || path.endsWith('/..') || path.endsWith('/');
    return trailing && !joined.endsWith('/') ? '$joined/' : joined;
  }

  /// Escapes code units <= 32, >= 127, "#" and "%" (upper-case hex).
  static String _escape(String text) {
    final out = StringBuffer();
    for (final unit in text.codeUnits) {
      if (unit <= 32 || unit >= 127 || unit == 0x23 || unit == 0x25) {
        out.write(
          '%${(unit & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      } else {
        out.writeCharCode(unit);
      }
    }
    return out.toString();
  }

  /// A host that is an IPv4 address in any notation (decimal, octal, hex,
  /// fewer than four parts) as four decimal parts; otherwise null.
  static String? _ipv4(String host) {
    final parts = host.split('.');
    if (parts.isEmpty || parts.length > 4) return null;
    final values = <int>[];
    for (final part in parts) {
      final int? value;
      if (RegExp(r'^0[xX][0-9a-fA-F]*$').hasMatch(part)) {
        value = part.length == 2
            ? 0
            : int.tryParse(part.substring(2), radix: 16);
      } else if (RegExp(r'^0[0-7]+$').hasMatch(part)) {
        value = int.tryParse(part.substring(1), radix: 8);
      } else if (RegExp(r'^\d+$').hasMatch(part)) {
        value = int.tryParse(part);
      } else {
        return null;
      }
      if (value == null) return null;
      values.add(value);
    }
    // The last part fills the remaining bytes.
    for (var i = 0; i < values.length - 1; i++) {
      if (values[i] > 255) return null;
    }
    final lastBytes = 5 - values.length;
    if (values.last >= (1 << (8 * lastBytes))) return null;
    final bytes = [...values.sublist(0, values.length - 1)];
    for (var i = lastBytes - 1; i >= 0; i--) {
      bytes.add((values.last >> (8 * i)) & 0xFF);
    }
    return bytes.join('.');
  }
}
