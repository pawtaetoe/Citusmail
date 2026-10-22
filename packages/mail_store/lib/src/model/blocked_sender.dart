// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a block matches.
enum BlockKind {
  /// One address, exactly (case-insensitive).
  address,

  /// Every address at a domain and its subdomains.
  domain,
}

/// A sender the user blocked. Blocks apply to every account: the user
/// blocks a person or company, not a mailbox.
final class BlockedSender {
  const BlockedSender({
    required this.id,
    required this.kind,
    required this.value,
    required this.since,
  });

  final int id;
  final BlockKind kind;

  /// Lower case: `news@shop.example`, or `shop.example`.
  final String value;

  /// When the block was made; mail received from then on is moved.
  final DateTime since;

  /// Whether mail from [address] (`local@domain`) is blocked by this.
  bool matches(String address) {
    final lower = address.toLowerCase();
    return switch (kind) {
      BlockKind.address => lower == value,
      BlockKind.domain => switch (lower.lastIndexOf('@')) {
        < 0 => false,
        final at => _inDomain(lower.substring(at + 1)),
      },
    };
  }

  bool _inDomain(String domain) =>
      domain == value || domain.endsWith('.$value');

  /// [value] cleaned for [kind], or throws [ArgumentError].
  static String normalize(BlockKind kind, String value) {
    final v = value.trim().toLowerCase();
    final ok = switch (kind) {
      BlockKind.address => RegExp(
        r'^[^\s@<>()]+@[a-z0-9-]+(\.[a-z0-9-]+)+$',
      ).hasMatch(v),
      BlockKind.domain => RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(v),
    };
    if (!ok || v.length > 320) {
      throw ArgumentError.value(value, 'value', 'not a ${kind.name}');
    }
    return v;
  }
}
