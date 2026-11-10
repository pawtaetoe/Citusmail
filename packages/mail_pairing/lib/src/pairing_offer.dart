// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'x25519.dart';

/// Addresses a pairing may use: the local network only. A QR code that
/// names anything else is refused, so a crafted code can't make the phone
/// send anything to the internet.
abstract final class LocalNetwork {
  /// Private IPv4 ranges (10/8, 172.16/12, 192.168/16), IPv4 link-local
  /// (169.254/16), IPv6 unique local addresses (fc00::/7) and loopback.
  static bool isLocal(InternetAddress address) {
    if (address.isLoopback) return true;
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 169 && b[1] == 254);
    }
    if (address.type == InternetAddressType.IPv6) {
      // An IPv4 address written as IPv6 (::ffff:a.b.c.d).
      final mapped =
          b.sublist(0, 10).every((x) => x == 0) &&
          b[10] == 0xFF &&
          b[11] == 0xFF;
      if (mapped) {
        return isLocal(InternetAddress.fromRawAddress(b.sublist(12)));
      }
      return (b[0] & 0xFE) == 0xFC;
    }
    return false;
  }

  /// This computer's addresses on the local network (not loopback; IPv6
  /// link-local addresses are left out, as they need a zone the phone
  /// can't know).
  static Future<List<InternetAddress>> ownAddresses() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: true,
    );
    final found = <InternetAddress>[
      for (final i in interfaces)
        for (final a in i.addresses)
          if (!a.isLoopback && isLocal(a)) a,
    ];
    // IPv4 first: home networks are nearly always IPv4.
    found.sort(
      (a, b) => a.type == b.type
          ? 0
          : a.type == InternetAddressType.IPv4
          ? -1
          : 1,
    );
    return found;
  }
}

/// What the computer's QR code says: where it listens on the local
/// network, its one-time public key, and a random one-time token.
///
/// Written as `citusmail-pair:?v=1&a=192.168.1.20&p=50123&k=...&t=...`
/// (key and token in base64url).
final class PairingOffer {
  PairingOffer({
    required List<InternetAddress> addresses,
    required this.port,
    required List<int> publicKey,
    required List<int> token,
  }) : addresses = List.unmodifiable(addresses),
       publicKey = Uint8List.fromList(publicKey),
       token = Uint8List.fromList(token) {
    if (this.publicKey.length != X25519.keyLength) {
      throw ArgumentError('the public key is 32 bytes');
    }
    if (this.token.length != tokenLength) {
      throw ArgumentError('the token is 16 bytes');
    }
    if (this.addresses.isNotEmpty && (port < 1 || port > 65535)) {
      throw ArgumentError('not a port');
    }
  }

  static const version = 1;
  static const scheme = 'citusmail-pair';
  static const tokenLength = 16;

  /// At most this many addresses in one code (keeps the QR code small).
  static const maxAddresses = 4;

  final List<InternetAddress> addresses;
  final int port;
  final Uint8List publicKey;
  final Uint8List token;

  /// Whether the phone can try to connect (no addresses: the computer
  /// isn't on a local network, and only the file route is left).
  bool get reachable => addresses.isNotEmpty;

  /// The text in the QR code.
  String encode() =>
      '$scheme:?v=$version'
      '${reachable ? '&a=${addresses.map((a) => a.address).join(',')}&p=$port' : ''}'
      '&k=${_b64(publicKey)}'
      '&t=${_b64(token)}';

  /// The offer in [text], or null if it isn't a Citusmail pairing code
  /// (another QR code, a newer version, or addresses outside the local
  /// network).
  static PairingOffer? decode(String text) {
    final Uri uri;
    try {
      uri = Uri.parse(text.trim());
    } on FormatException {
      return null;
    }
    if (uri.scheme != scheme) return null;
    final q = uri.queryParameters;
    if (q['v'] != '$version') return null;
    final port = q['a'] == null ? 0 : int.tryParse(q['p'] ?? '');
    final key = _unb64(q['k']);
    final token = _unb64(q['t']);
    final addresses = <InternetAddress>[];
    for (final part in q['a']?.split(',') ?? const <String>[]) {
      final address = InternetAddress.tryParse(part);
      if (address == null || !LocalNetwork.isLocal(address)) return null;
      addresses.add(address);
    }
    if (port == null ||
        (addresses.isNotEmpty && (port < 1 || port > 65535)) ||
        key?.length != X25519.keyLength ||
        token?.length != tokenLength ||
        addresses.length > maxAddresses) {
      return null;
    }
    return PairingOffer(
      addresses: addresses,
      port: port,
      publicKey: key!,
      token: token!,
    );
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List? _unb64(String? text) {
    if (text == null || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(text)) {
      return null;
    }
    try {
      return base64Url.decode(base64Url.normalize(text));
    } on FormatException {
      return null;
    }
  }
}
