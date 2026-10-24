// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// What the sync engine remembers about a folder between syncs.
final class MailboxSyncState {
  const MailboxSyncState({
    this.uidValidity,
    this.uidNext,
    this.highestModSeq,
    this.lastSyncAt,
  });

  static const MailboxSyncState empty = MailboxSyncState();

  /// Null until the first sync.
  final int? uidValidity;
  final int? uidNext;

  /// Null if the server does not track changes; then only full resyncs.
  final int? highestModSeq;
  final DateTime? lastSyncAt;
}

/// A folder of an account.
final class StoredMailbox {
  const StoredMailbox({
    required this.id,
    required this.accountId,
    required this.encodedName,
    required this.name,
    required this.selectable,
    required this.syncState,
    this.delimiter,
    this.specialUse,
  });

  final int id;
  final int accountId;

  /// Name as the server knows it (use in IMAP commands).
  final String encodedName;

  /// Readable name.
  final String name;
  final String? delimiter;
  final SpecialUse? specialUse;
  final bool selectable;
  final MailboxSyncState syncState;

  bool get isInbox => encodedName.toUpperCase() == 'INBOX';

  /// A folder that only shows mail kept in other folders: Gmail's Starred
  /// and Important (\Flagged, \Important). Not synced in the background,
  /// only when opened; its copies are left out of lists across folders.
  bool get isView =>
      specialUse == SpecialUse.flagged || specialUse == SpecialUse.important;

  /// Special uses whose copies duplicate mail in other folders (Gmail's
  /// All Mail, Starred, Important), as stored in the database.
  static const copyUses = ['all', 'flagged', 'important'];

  /// The folder that carries the app's encrypted sync data. Never shown or
  /// synced as mail.
  static const appDataName = 'Citusmail Sync';

  /// Whether this is the app's sync data folder (also when it lives under
  /// `INBOX.` on cPanel-style servers).
  bool get isAppData =>
      name == appDataName || name.split(delimiter ?? '/').last == appDataName;

  @override
  String toString() => 'StoredMailbox($id, $name)';
}
