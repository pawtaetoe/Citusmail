// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// The host names a certificate is issued for, and whether one of them
/// covers a given host. Used only to explain a rejected certificate and to
/// pick a name worth trying; the connection itself is always checked by
/// the TLS library against the name actually connected to.
abstract final class CertificateNames {
  /// The DNS names in the subject alternative name extension of a DER
  /// encoded X.509 certificate, lower-cased. Empty when there is none or
  /// the certificate can't be read.
  static List<String> fromDer(Uint8List der) {
    try {
      final certificate = _Der(der).single(0, der.length, 0x30);
      final tbs = _Der(der).children(certificate.$1, certificate.$2).first;
      if (tbs.tag != 0x30) return const [];
      for (final field in _Der(der).children(tbs.start, tbs.end)) {
        if (field.tag != 0xA3) continue; // [3] extensions
        final extensions = _Der(der).single(field.start, field.end, 0x30);
        for (final extension in _Der(
          der,
        ).children(extensions.$1, extensions.$2)) {
          if (extension.tag != 0x30) continue;
          final parts = _Der(der).children(extension.start, extension.end);
          if (parts.isEmpty || parts.first.tag != 0x06) continue;
          if (!_isSan(der, parts.first)) continue;
          final value = parts.lastWhere((p) => p.tag == 0x04);
          final names = _Der(der).single(value.start, value.end, 0x30);
          return [
            for (final name in _Der(der).children(names.$1, names.$2))
              if (name.tag == 0x82) // [2] dNSName, an IA5String
                String.fromCharCodes(der, name.start, name.end).toLowerCase(),
          ];
        }
      }
    } on FormatException {
      // fall through
    } on StateError {
      // fall through
    }
    return const [];
  }

  /// OID 2.5.29.17, subjectAltName.
  static bool _isSan(Uint8List der, _Tlv oid) =>
      oid.end - oid.start == 3 &&
      der[oid.start] == 0x55 &&
      der[oid.start + 1] == 0x1D &&
      der[oid.start + 2] == 0x11;

  /// Whether a certificate issued for [names] is valid for [host], by the
  /// rules browsers and mail clients use (RFC 6125): an exact match, or a
  /// wildcard that stands for exactly one whole left-most label.
  /// `*.web-hosting.com` covers `business905-5.web-hosting.com`, but not
  /// `a.b.web-hosting.com` or `web-hosting.com`. A wildcard needs at
  /// least two labels after it (`*.com` covers nothing).
  static bool covers(Iterable<String> names, String host) {
    final target = _normalize(host);
    if (target.isEmpty || !target.contains('.')) return false;
    // IP addresses are never matched against DNS names.
    if (RegExp(r'^[0-9.]+$').hasMatch(target) || target.contains(':')) {
      return false;
    }
    for (final raw in names) {
      final name = _normalize(raw);
      if (name.isEmpty) continue;
      if (!name.contains('*')) {
        if (name == target) return true;
        continue;
      }
      if (!name.startsWith('*.')) continue; // partial wildcards: no
      final suffix = name.substring(2);
      if (suffix.contains('*') || suffix.split('.').length < 2) continue;
      final dot = target.indexOf('.');
      if (dot <= 0) continue;
      if (target.substring(dot + 1) == suffix) return true;
    }
    return false;
  }

  static String _normalize(String name) =>
      name.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
}

/// One DER element: its tag and where its contents are.
typedef _Tlv = ({int tag, int start, int end});

/// A minimal DER reader: just enough to walk to an extension.
final class _Der {
  const _Der(this.data);

  final Uint8List data;

  /// The element at [at], bounded by [limit].
  _Tlv read(int at, int limit) {
    if (at + 2 > limit) throw const FormatException('DER truncated');
    final tag = data[at];
    if (tag & 0x1F == 0x1F) throw const FormatException('DER long tag');
    var length = data[at + 1];
    var start = at + 2;
    if (length & 0x80 != 0) {
      final bytes = length & 0x7F;
      if (bytes == 0 || bytes > 4 || start + bytes > limit) {
        throw const FormatException('DER length');
      }
      length = 0;
      for (var i = 0; i < bytes; i++) {
        length = (length << 8) | data[start + i];
      }
      start += bytes;
    }
    final end = start + length;
    if (end > limit) throw const FormatException('DER truncated');
    return (tag: tag, start: start, end: end);
  }

  /// The elements between [start] and [end].
  List<_Tlv> children(int start, int end) {
    final out = <_Tlv>[];
    var at = start;
    while (at < end) {
      final element = read(at, end);
      out.add(element);
      at = element.end;
      if (out.length > 1000) throw const FormatException('DER too long');
    }
    return out;
  }

  /// The contents of the one element at [start], which must have [tag].
  (int, int) single(int start, int end, int tag) {
    final element = read(start, end);
    if (element.tag != tag) throw const FormatException('DER unexpected');
    return (element.start, element.end);
  }
}
