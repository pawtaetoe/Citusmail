// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../ids.dart';

/// A draft as stored. The store does not interpret [content] (the compose
/// package owns its format); attachments are kept as separate rows.
final class StoredDraft {
  const StoredDraft({
    required this.id,
    required this.accountId,
    required this.content,
    required this.updatedAt,
    this.savedMessageId,
  });

  final int id;
  final AccountId accountId;
  final String content;

  /// Message-ID of the copy in the server's Drafts folder, if any.
  final String? savedMessageId;
  final DateTime updatedAt;
}

/// A file attached to a draft.
final class StoredDraftAttachment {
  const StoredDraftAttachment({
    required this.fileName,
    required this.mimeType,
    required this.data,
  });

  final String fileName;
  final String mimeType;
  final Uint8List data;
}
