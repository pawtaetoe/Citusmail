// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../database/mail_database.dart';
import '../model/draft.dart';

/// Drafts being written, stored encrypted like everything else.
final class DraftRepository {
  DraftRepository(this._db);

  final MailDatabase _db;

  static const _columns =
      'id, account_id, content, saved_message_id, updated_at';

  /// Creates a draft or replaces one, with its attachments, atomically.
  /// Returns the draft's id.
  int save({
    int? id,
    required int accountId,
    required String content,
    required List<StoredDraftAttachment> attachments,
    String? savedMessageId,
  }) => _db.transaction(() {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final int draftId;
    if (id == null) {
      _db.execute(
        'INSERT INTO drafts (account_id, content, saved_message_id, updated_at) VALUES (?, ?, ?, ?)',
        [accountId, content, savedMessageId, now],
      );
      draftId = _db.lastInsertRowId;
    } else {
      _db.execute(
        'UPDATE drafts SET account_id = ?, content = ?, saved_message_id = ?, updated_at = ? WHERE id = ?',
        [accountId, content, savedMessageId, now, id],
      );
      if (_db.updatedRows == 0) throw StateError('draft $id no longer exists');
      draftId = id;
      _db.execute('DELETE FROM draft_attachments WHERE draft_id = ?', [id]);
    }
    _db.executeMany(
      'INSERT INTO draft_attachments (draft_id, position, file_name, mime_type, data) VALUES (?, ?, ?, ?, ?)',
      [
        for (var i = 0; i < attachments.length; i++)
          [
            draftId,
            i,
            attachments[i].fileName,
            attachments[i].mimeType,
            attachments[i].data,
          ],
      ],
    );
    return draftId;
  });

  StoredDraft? byId(int id) {
    final rows = _db.select('SELECT $_columns FROM drafts WHERE id = ?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every stored draft, oldest first.
  List<StoredDraft> all() => _db
      .select('SELECT $_columns FROM drafts ORDER BY id')
      .map(_fromRow)
      .toList(growable: false);

  List<StoredDraftAttachment> attachments(int draftId) => _db
      .select(
        'SELECT file_name, mime_type, data FROM draft_attachments WHERE draft_id = ? ORDER BY position',
        [draftId],
      )
      .map(
        (r) => StoredDraftAttachment(
          fileName: r['file_name'] as String,
          mimeType: r['mime_type'] as String,
          data: r['data'] as Uint8List,
        ),
      )
      .toList(growable: false);

  void delete(int id) => _db.execute('DELETE FROM drafts WHERE id = ?', [id]);

  static StoredDraft _fromRow(Row row) => StoredDraft(
    id: row['id'] as int,
    accountId: row['account_id'] as int,
    content: row['content'] as String,
    savedMessageId: row['saved_message_id'] as String?,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      row['updated_at'] as int,
      isUtc: true,
    ),
  );
}
