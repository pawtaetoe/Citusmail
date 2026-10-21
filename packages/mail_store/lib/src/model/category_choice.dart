// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'message.dart';

/// What a category choice applies to.
enum ChoiceScope {
  /// Every message from one address.
  sender,

  /// Every message of one mailing list (by List-Id), whoever posted it.
  list,
}

/// The user's "Move to People / Newsletters / Notifications" for a sender
/// or a mailing list. It decides the category of earlier and later
/// messages, ahead of any rule.
final class CategoryChoice {
  /// [key] is an address (sender) or a List-Id (list). It is stored in
  /// ASCII lower case, matching how the database compares addresses.
  CategoryChoice({
    required this.scope,
    required String key,
    required this.category,
    DateTime? updatedAt,
  }) : key = normalizeKey(key),
       updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  static const maxKeyLength = 512;

  final ChoiceScope scope;
  final String key;
  final MessageCategory category;
  final DateTime updatedAt;

  /// Trims and lower-cases ASCII letters only. SQLite's NOCASE comparison
  /// also folds only ASCII, so both sides always agree.
  static String normalizeKey(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty || trimmed.length > maxKeyLength) {
      throw ArgumentError.value(
        key,
        'key',
        'must be 1 to $maxKeyLength characters',
      );
    }
    return asciiLowerCase(trimmed);
  }

  /// Lower-cases A-Z, leaving every other character as it is.
  static String asciiLowerCase(String s) => String.fromCharCodes([
    for (final c in s.codeUnits) c >= 0x41 && c <= 0x5A ? c + 0x20 : c,
  ]);

  @override
  bool operator ==(Object other) =>
      other is CategoryChoice &&
      other.scope == scope &&
      other.key == key &&
      other.category == category;

  @override
  int get hashCode => Object.hash(scope, key, category);

  @override
  String toString() => 'CategoryChoice(${scope.name} $key -> ${category.name})';
}
