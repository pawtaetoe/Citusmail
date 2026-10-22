// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// What a folder rule looks at.
enum RuleField {
  /// The sender's address, exactly (ignoring case).
  fromAddress,

  /// The sender's domain, or any of its subdomains.
  fromDomain,

  /// An address in To or Cc (for aliases), exactly (ignoring case).
  toAddress,

  /// Text the subject contains (ignoring case).
  subject,
}

/// "Mail matching this goes to that folder": a custom folder's rule.
final class FolderRule {
  const FolderRule({
    required this.id,
    required this.accountId,
    required this.mailboxId,
    required this.field,
    required this.value,
    required this.appliesFrom,
    required this.createdAt,
  });

  final int id;
  final int accountId;

  /// The folder mail is moved to.
  final int mailboxId;
  final RuleField field;

  /// Stored trimmed and in lower case.
  final String value;

  /// Only mail received at or after this moves (the epoch for "also move
  /// mail that is already in the inbox").
  final DateTime appliesFrom;
  final DateTime createdAt;

  static const maxValueLength = 320;

  /// [value] as it is stored and compared: trimmed, lower case (ASCII and
  /// beyond, since subjects can be in any script), without a leading "@"
  /// for domains.
  static String normalize(RuleField field, String value) {
    var v = value.trim().toLowerCase();
    if (field == RuleField.fromDomain && v.startsWith('@')) v = v.substring(1);
    if (v.isEmpty || v.length > maxValueLength) {
      throw ArgumentError.value(
        value,
        'value',
        'must be 1 to $maxValueLength characters',
      );
    }
    if ((field == RuleField.fromAddress || field == RuleField.toAddress) &&
        !RegExp(r'^[^\s@]+@[^\s@]+$').hasMatch(v)) {
      throw ArgumentError.value(value, 'value', 'not an email address');
    }
    if (field == RuleField.fromDomain &&
        !RegExp(r'^[^\s@]+\.[^\s@]+$').hasMatch(v)) {
      throw ArgumentError.value(value, 'value', 'not a domain');
    }
    return v;
  }
}
