// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

/// An action done locally that the server must also get. Every action is
/// idempotent: replaying it after a crash or on another device's changes
/// is harmless (a message already gone counts as done).
sealed class OutboxAction {
  const OutboxAction();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  /// Parses a stored action. Throws [FormatException] for anything that is
  /// not a valid action, so a corrupted entry fails instead of misbehaving.
  static OutboxAction decode(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, Object?>) {
      throw const FormatException('action is not an object');
    }
    return switch (json['type']) {
      'setFlags' => SetFlagsAction(
        mailboxId: _int(json, 'mailboxId'),
        uids: _ints(json, 'uids'),
        add: _strings(json, 'add'),
        remove: _strings(json, 'remove'),
      ),
      'move' => MoveAction(
        mailboxId: _int(json, 'mailboxId'),
        uids: _ints(json, 'uids'),
        targetMailboxId: _int(json, 'targetMailboxId'),
      ),
      'delete' => DeleteAction(
        mailboxId: _int(json, 'mailboxId'),
        uids: _ints(json, 'uids'),
      ),
      'append' => AppendAction(
        mailboxId: _int(json, 'mailboxId'),
        flags: _strings(json, 'flags'),
      ),
      'send' => SendAction(
        from: _string(json, 'from'),
        recipients: _strings(json, 'recipients'),
        sentMailboxId: json['sentMailboxId'] == null
            ? null
            : _int(json, 'sentMailboxId'),
      ),
      _ => throw FormatException('unknown action type ${json['type']}'),
    };
  }

  static int _int(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! int) throw FormatException('$key must be an integer');
    return value;
  }

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String) throw FormatException('$key must be a string');
    return value;
  }

  static List<int> _ints(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! List || value.any((v) => v is! int || v < 1)) {
      throw FormatException('$key must be a list of UIDs');
    }
    return List<int>.unmodifiable(value.cast<int>());
  }

  static List<String> _strings(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! List || value.any((v) => v is! String)) {
      throw FormatException('$key must be a list of strings');
    }
    return List<String>.unmodifiable(value.cast<String>());
  }
}

/// Add and/or remove flags (read, flagged...).
final class SetFlagsAction extends OutboxAction {
  SetFlagsAction({
    required this.mailboxId,
    required List<int> uids,
    List<String> add = const [],
    List<String> remove = const [],
  }) : uids = List.unmodifiable(uids),
       add = List.unmodifiable(add),
       remove = List.unmodifiable(remove) {
    _requireUids(this.uids);
    if (add.isEmpty && remove.isEmpty) throw ArgumentError('nothing to change');
  }

  final int mailboxId;
  final List<int> uids;
  final List<String> add;
  final List<String> remove;

  @override
  Map<String, Object?> toJson() => {
    'type': 'setFlags',
    'mailboxId': mailboxId,
    'uids': uids,
    'add': add,
    'remove': remove,
  };
}

/// Move messages to another folder (archive, sort into a folder...).
final class MoveAction extends OutboxAction {
  MoveAction({
    required this.mailboxId,
    required List<int> uids,
    required this.targetMailboxId,
  }) : uids = List.unmodifiable(uids) {
    _requireUids(this.uids);
    if (mailboxId == targetMailboxId) {
      throw ArgumentError('source and target are the same folder');
    }
  }

  final int mailboxId;
  final List<int> uids;
  final int targetMailboxId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'move',
    'mailboxId': mailboxId,
    'uids': uids,
    'targetMailboxId': targetMailboxId,
  };
}

/// Delete messages: move them to Trash, or remove them for good when
/// they already are in Trash.
final class DeleteAction extends OutboxAction {
  DeleteAction({required this.mailboxId, required List<int> uids})
    : uids = List.unmodifiable(uids) {
    _requireUids(this.uids);
  }

  final int mailboxId;
  final List<int> uids;

  @override
  Map<String, Object?> toJson() => {
    'type': 'delete',
    'mailboxId': mailboxId,
    'uids': uids,
  };
}

/// Store a message (the entry's data) in a folder, e.g. a draft.
final class AppendAction extends OutboxAction {
  AppendAction({required this.mailboxId, List<String> flags = const []})
    : flags = List.unmodifiable(flags);

  final int mailboxId;
  final List<String> flags;

  @override
  Map<String, Object?> toJson() => {
    'type': 'append',
    'mailboxId': mailboxId,
    'flags': flags,
  };
}

/// Send a built message (the entry's data) and save it to Sent.
final class SendAction extends OutboxAction {
  SendAction({
    required this.from,
    required List<String> recipients,
    this.sentMailboxId,
  }) : recipients = List.unmodifiable(recipients) {
    if (this.recipients.isEmpty) throw ArgumentError('no recipients');
  }

  /// Envelope sender address.
  final String from;

  /// Envelope recipient addresses (To, Cc and Bcc).
  final List<String> recipients;
  final int? sentMailboxId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'send',
    'from': from,
    'recipients': recipients,
    'sentMailboxId': sentMailboxId,
  };
}

void _requireUids(List<int> uids) {
  if (uids.isEmpty || uids.any((u) => u < 1)) {
    throw ArgumentError('UIDs must be at least 1');
  }
}

/// Whether the entry is waiting or has given up.
enum OutboxState { pending, failed }

/// A queued action as stored.
final class OutboxEntry {
  const OutboxEntry({
    required this.id,
    required this.accountId,
    required this.action,
    required this.state,
    required this.attempts,
    required this.createdAt,
    required this.notBefore,
    this.data,
    this.lastError,
  });

  final int id;
  final int accountId;
  final OutboxAction action;

  /// Raw message bytes for append and send.
  final Uint8List? data;
  final OutboxState state;
  final int attempts;
  final String? lastError;
  final DateTime createdAt;

  /// Retry no earlier than this (backoff after failures).
  final DateTime notBefore;
}
