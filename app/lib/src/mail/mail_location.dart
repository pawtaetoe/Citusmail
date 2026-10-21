// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

/// What the message list shows.
sealed class MailLocation {
  const MailLocation();

  /// The account it is limited to, or null for all accounts.
  int? get accountId => null;
}

/// The inbox of every account (or one), in Smart or Classic layout.
final class InboxLocation extends MailLocation {
  const InboxLocation({this.accountId});

  @override
  final int? accountId;

  @override
  bool operator ==(Object other) =>
      other is InboxLocation && other.accountId == accountId;

  @override
  int get hashCode => Object.hash(InboxLocation, accountId);
}

/// All messages of one Smart Inbox section ("Show all").
final class SectionLocation extends MailLocation {
  const SectionLocation(this.section, {this.accountId});

  final SmartSection section;

  @override
  final int? accountId;

  @override
  bool operator ==(Object other) =>
      other is SectionLocation &&
      other.section == section &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(SectionLocation, section, accountId);
}

/// One server folder.
final class FolderLocation extends MailLocation {
  const FolderLocation(this.mailboxId, this.accountId);

  final int mailboxId;

  @override
  final int accountId;

  @override
  bool operator ==(Object other) =>
      other is FolderLocation && other.mailboxId == mailboxId;

  @override
  int get hashCode => Object.hash(FolderLocation, mailboxId);
}

/// Pinned messages in every folder of every account.
final class PinsLocation extends MailLocation {
  const PinsLocation();

  @override
  bool operator ==(Object other) => other is PinsLocation;

  @override
  int get hashCode => (PinsLocation).hashCode;
}

/// Search results across everything stored.
final class SearchLocation extends MailLocation {
  const SearchLocation(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is SearchLocation && other.text == text;

  @override
  int get hashCode => Object.hash(SearchLocation, text);
}
