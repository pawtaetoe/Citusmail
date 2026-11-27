// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';

/// Whether [a] and [b] are the same message with the same stored values:
/// read again from the store, it would show the same. Lets the screen skip
/// rebuilding when a refresh found nothing new.
bool sameMessage(StoredMessage? a, StoredMessage? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.id == b.id &&
      a.mailboxId == b.mailboxId &&
      a.accountId == b.accountId &&
      a.uid == b.uid &&
      a.messageId == b.messageId &&
      a.inReplyTo == b.inReplyTo &&
      listEquals(a.references, b.references) &&
      a.subject == b.subject &&
      a.from?.displayName == b.from?.displayName &&
      a.from?.address == b.from?.address &&
      a.sentAt == b.sentAt &&
      a.receivedAt == b.receivedAt &&
      a.listedAt == b.listedAt &&
      a.size == b.size &&
      a.flags == b.flags &&
      a.modSeq == b.modSeq &&
      a.hasAttachments == b.hasAttachments &&
      a.category == b.category &&
      a.categorySource == b.categorySource &&
      a.snippet == b.snippet &&
      a.listId == b.listId &&
      a.section == b.section &&
      a.code == b.code;
}

/// [sameMessage] for each of two lists, in order.
bool sameMessages(List<StoredMessage> a, List<StoredMessage> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!sameMessage(a[i], b[i])) return false;
  }
  return true;
}
