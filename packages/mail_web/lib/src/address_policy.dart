// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';
import 'dart:typed_data';

/// Which internet addresses a request from mail may go to.
abstract interface class AddressPolicy {
  bool allows(InternetAddress address);
}

/// Only addresses on the public internet.
///
/// A link in a message must never make the device talk to the user's own
/// network (router admin pages, printers, `localhost` services): a POST to
/// `192.168.1.1` from an "unsubscribe" header would be an attack on the
/// user's home. So loopback, private, link-local, carrier-grade NAT,
/// multicast, documentation and reserved ranges are refused, also when
/// they hide inside IPv6 (mapped, NAT64, 6to4).
final class PublicAddressPolicy implements AddressPolicy {
  const PublicAddressPolicy();

  @override
  bool allows(InternetAddress address) => switch (address.type) {
    InternetAddressType.IPv4 => _publicV4(address.rawAddress),
    InternetAddressType.IPv6 => _publicV6(address.rawAddress),
    _ => false,
  };

  static bool _publicV4(Uint8List a) {
    if (a.length != 4) return false;
    final (b0, b1, b2) = (a[0], a[1], a[2]);
    // This network, private, loopback.
    if (b0 == 0 || b0 == 10 || b0 == 127) return false;
    if (b0 == 100 && b1 >= 64 && b1 <= 127) return false; // carrier-grade NAT
    if (b0 == 169 && b1 == 254) return false; // link-local
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return false; // private
    if (b0 == 192 && b1 == 168) return false; // private
    // IETF protocol assignments, documentation.
    if (b0 == 192 && b1 == 0 && (b2 == 0 || b2 == 2)) return false;
    if (b0 == 192 && b1 == 88 && b2 == 99) return false; // 6to4 relay
    if (b0 == 198 && (b1 == 18 || b1 == 19)) return false; // benchmarking
    if (b0 == 198 && b1 == 51 && b2 == 100) return false; // docs
    if (b0 == 203 && b1 == 0 && b2 == 113) return false; // docs
    if (b0 >= 224) return false; // multicast, reserved, broadcast
    return true;
  }

  static bool _publicV6(Uint8List a) {
    if (a.length != 16) return false;
    bool zeros(int from, int to) {
      for (var i = from; i < to; i++) {
        if (a[i] != 0) return false;
      }
      return true;
    }

    if (zeros(0, 15) && (a[15] == 0 || a[15] == 1)) return false; // ::, ::1
    // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible): judge the IPv4.
    if (zeros(0, 10) && a[10] == 0xFF && a[11] == 0xFF) {
      return _publicV4(Uint8List.sublistView(a, 12));
    }
    if (zeros(0, 12)) return _publicV4(Uint8List.sublistView(a, 12));
    // 64:ff9b::/96 (NAT64) carries an IPv4 address too.
    if (a[0] == 0x00 && a[1] == 0x64 && a[2] == 0xFF && a[3] == 0x9B) {
      return zeros(4, 12) && _publicV4(Uint8List.sublistView(a, 12));
    }
    // 2002::/16 (6to4) carries an IPv4 address in bytes 2-5.
    if (a[0] == 0x20 && a[1] == 0x02) {
      return _publicV4(Uint8List.sublistView(a, 2, 6));
    }
    if ((a[0] & 0xFE) == 0xFC) return false; // fc00::/7 unique local
    if (a[0] == 0xFE && (a[1] & 0xC0) == 0x80) return false; // fe80::/10
    if (a[0] == 0xFE && (a[1] & 0xC0) == 0xC0) return false; // fec0::/10
    if (a[0] == 0xFF) return false; // multicast
    if (a[0] == 0x20 && a[1] == 0x01 && a[2] == 0x0D && a[3] == 0xB8) {
      return false; // 2001:db8::/32 documentation
    }
    if (a[0] == 0x01 && zeros(1, 8)) return false; // 100::/64 discard
    // 2001::/23 IETF special purpose (Teredo and others).
    if (a[0] == 0x20 && a[1] == 0x01 && a[2] < 0x02) return false;
    return (a[0] & 0xE0) == 0x20; // global unicast is 2000::/3
  }
}
