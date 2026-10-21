// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';
import 'dart:typed_data';

/// The 256-bit key that encrypts the local database.
///
/// Generated once per device and kept in the platform keychain by the app;
/// never derived from a user password and never written anywhere else.
final class DatabaseKey {
  DatabaseKey._(this._bytes);

  /// A new random key from the operating system's secure generator.
  factory DatabaseKey.generate() {
    final random = Random.secure();
    return DatabaseKey._(
      Uint8List.fromList(List.generate(length, (_) => random.nextInt(256))),
    );
  }

  /// A key previously generated and stored (e.g. read from the keychain).
  factory DatabaseKey.fromBytes(List<int> bytes) {
    if (bytes.length != length || bytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('a database key is exactly $length bytes');
    }
    return DatabaseKey._(Uint8List.fromList(bytes));
  }

  /// Key size in bytes.
  static const int length = 32;

  final Uint8List _bytes;

  /// Copy of the key bytes, for storing in the keychain.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  /// Lower-case hex, for `PRAGMA hexkey`. Only ever [0-9a-f]{64}.
  String get hex =>
      _bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Never prints the key.
  @override
  String toString() => 'DatabaseKey(redacted)';
}
