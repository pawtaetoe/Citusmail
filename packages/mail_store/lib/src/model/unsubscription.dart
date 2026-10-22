// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// How the user unsubscribed.
enum UnsubscribeKind {
  /// The app sent the sender's one-click request.
  oneClick,

  /// The app sent an unsubscribe email.
  email,

  /// The user was sent to the sender's unsubscribe page (whether they
  /// finished there is unknown).
  webPage,
}

/// A list the user unsubscribed from.
final class Unsubscription {
  const Unsubscription({
    required this.id,
    required this.accountId,
    required this.listKey,
    required this.listName,
    required this.kind,
    required this.at,
  });

  final int id;
  final int accountId;

  /// See [listKeyOf].
  final String listKey;

  /// As shown to the user ("Shop Weekly").
  final String listName;
  final UnsubscribeKind kind;
  final DateTime at;

  /// What identifies a list: its List-Id when it has one (several senders
  /// can share it), otherwise the sender's address.
  static String? listKeyOf({String? listId, String? fromAddress}) {
    if (listId != null && listId.isNotEmpty) {
      return 'list:${listId.toLowerCase()}';
    }
    if (fromAddress != null && fromAddress.isNotEmpty) {
      return 'from:${fromAddress.toLowerCase()}';
    }
    return null;
  }
}
