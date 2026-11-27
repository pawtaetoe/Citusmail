// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../inbox/state/location_controller.dart';
import '../../inbox/state/mail_counts.dart';
import '../../inbox/state/mail_location.dart';

/// The user's own folders: creating them, where a message can be moved,
/// and the rules that file mail into them.
final class FolderController {
  FolderController(this._store, this._worker, this._location, this._counts);

  final MailStore _store;
  final SyncWorker _worker;
  final LocationController _location;
  final CountsController _counts;
  bool _disposed = false;

  /// Creates a folder on the server and opens it. Returns an error to
  /// show, or null on success.
  Future<String?> createFolder(int accountId, String name) async {
    try {
      final id = await _worker.createFolder(accountId, name);
      if (!_disposed) {
        _counts.refresh();
        _location.goTo(FolderLocation(id, accountId));
      }
      return null;
    } on ArgumentError catch (e) {
      return refusedName(e.message);
    } on SyncWorkerException catch (e) {
      return e.failure.kind == SyncFailureKind.network
          ? 'Folders can only be created while online.'
          : 'The server refused: ${e.failure.message}';
    }
  }

  /// Folders a message can be moved to.
  List<StoredMailbox> moveTargets(StoredMessage m) => [
    for (final box in _store.mailboxes.forAccount(m.accountId))
      if (box.selectable && box.id != m.mailboxId && !box.isAppData) box,
  ];

  /// Whether rules can move mail into [mailbox] (not the inbox, Drafts or
  /// Sent).
  static bool canHaveRules(StoredMailbox mailbox) =>
      !mailbox.isInbox &&
      mailbox.selectable &&
      mailbox.specialUse != SpecialUse.drafts &&
      mailbox.specialUse != SpecialUse.sent;

  List<FolderRule> rulesFor(int mailboxId) =>
      _store.folderRules.forMailbox(mailboxId);

  /// Adds a rule; with [includeExisting] the inbox is filed with the next
  /// sync. Returns an error to show, or null.
  String? addRule(
    StoredMailbox mailbox,
    RuleField field,
    String value, {
    bool includeExisting = false,
  }) {
    try {
      _store.folderRules.add(
        accountId: mailbox.accountId,
        mailboxId: mailbox.id,
        field: field,
        value: value,
        includeExisting: includeExisting,
      );
    } on ArgumentError {
      return switch (field) {
        RuleField.fromAddress ||
        RuleField.toAddress => 'Enter an email address.',
        RuleField.fromDomain => 'Enter a domain, like example.com.',
        RuleField.subject => 'Enter some text.',
      };
    }
    if (includeExisting) _worker.requestSync(mailbox.accountId);
    return null;
  }

  void removeRule(FolderRule rule) => _store.folderRules.remove(rule.id);

  /// Says why the sync layer refused a folder name, from its error
  /// [message].
  static String refusedName(Object? message) => switch (message) {
    final String message when message.contains('separator') => switch (RegExp(
      '"([^"]+)"',
    ).firstMatch(message)?.group(1)) {
      final separator? =>
        'Folder names can\'t contain "$separator" on this server.',
      null => 'Folder names can\'t contain this server\'s separator.',
    },
    final String message when message.contains('INBOX') =>
      'Inbox already exists.',
    _ => 'That can\'t be a folder name.',
  };

  void dispose() => _disposed = true;
}
