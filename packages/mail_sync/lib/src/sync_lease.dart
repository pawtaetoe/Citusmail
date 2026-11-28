// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// A folder's UIDVALIDITY changed while a sync had handed its connection
/// over: the UIDs it was working with mean nothing now.
final class FolderResetException extends MailException {
  const FolderResetException(this.encodedName, this.uidValidity)
    : super('the folder was reset on the server');

  final String encodedName;

  /// The folder's UIDVALIDITY now.
  final int uidValidity;
}

/// The connection a sync works on, which it hands to the user's work
/// waiting for one between two batches of a long step (a FETCH of
/// summaries, a chunk of flags, a back-fill search): see
/// docs/architecture.md, "Connections".
///
/// The work calls [resume] before each batch and [advanced] after it. A
/// handover only happens after at least one batch since the last one, so
/// the sync always moves on, however much the user does.
abstract class SyncLease {
  SyncLease();

  /// A lease of [client] alone, which never hands it over (on-demand
  /// work, and tests).
  factory SyncLease.fixed(ImapClient client) = _FixedLease;

  /// The connection to work on now. It can change at each [resume].
  ImapClient get client;

  /// A batch of work is done (its result stored): the next [resume] may
  /// hand the connection over.
  void advanced();

  /// Hands the connection to the user's work waiting for one, if any and
  /// if a batch was [advanced] since the last time, and takes one back
  /// (maybe another connection). Returns whether it did.
  Future<bool> handOverIfWanted();

  /// Before the next batch in the folder [encodedName], expected at
  /// [uidValidity]: hands over if wanted ([handOverIfWanted]), then
  /// selects the folder again (EXAMINE, with [readOnly]) after a
  /// hand-over, or if the connection has another one selected. After a
  /// hand-over always: the connection that comes back may be another one,
  /// kept with the folder open since long ago, its view of it stale.
  /// Throws [FolderResetException] when the folder's UIDVALIDITY changed
  /// meanwhile.
  Future<ImapClient> resume(
    String encodedName,
    int uidValidity, {
    bool readOnly = true,
  }) async {
    final handed = await handOverIfWanted();
    final imap = client;
    var selected = imap.selected;
    if (!handed && selected?.name == encodedName) return imap;
    selected = await imap.select(encodedName, readOnly: readOnly);
    if (selected.uidValidity != uidValidity) {
      throw FolderResetException(encodedName, selected.uidValidity);
    }
    return imap;
  }
}

final class _FixedLease extends SyncLease {
  _FixedLease(this.client);

  @override
  final ImapClient client;

  @override
  void advanced() {}

  @override
  Future<bool> handOverIfWanted() async => false;
}
