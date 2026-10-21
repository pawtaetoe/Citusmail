// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

/// An action done locally that the server must also get. Every action is
/// idempotent: replaying it after a crash or after another device's changes
/// is harmless (a message already gone counts as done).
sealed class OutboxAction {
  const OutboxAction();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  /// Parses a stored action. Throws [FormatException] for anything that is
  /// not a valid action, so a corrupted entry fails instead of misbehaving.
  static OutboxAction decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const FormatException('action is not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('action is not an object');
    }
    try {
      return switch (json['type']) {
        'setFlags' => SetFlagsAction(
          mailboxId: _int(json, 'mailboxId'),
          uidValidity: _int(json, 'uidValidity'),
          uids: _uids(json),
          add: _strings(json, 'add'),
          remove: _strings(json, 'remove'),
        ),
        'move' => MoveAction(
          mailboxId: _int(json, 'mailboxId'),
          uidValidity: _int(json, 'uidValidity'),
          uids: _uids(json),
          targetMailboxId: _int(json, 'targetMailboxId'),
        ),
        'delete' => DeleteAction(
          mailboxId: _int(json, 'mailboxId'),
          uidValidity: _int(json, 'uidValidity'),
          uids: _uids(json),
        ),
        'append' => AppendAction(
          mailboxId: _int(json, 'mailboxId'),
          flags: _strings(json, 'flags'),
        ),
        'removeDraft' => RemoveDraftAction(
          mailboxId: _int(json, 'mailboxId'),
          messageId: _string(json, 'messageId'),
        ),
        'send' => SendAction(
          from: _string(json, 'from'),
          recipients: _strings(json, 'recipients'),
          sentMailboxId: json['sentMailboxId'] == null
              ? null
              : _int(json, 'sentMailboxId'),
          smtpAccepted: json['smtpAccepted'] == true,
        ),
        _ => throw FormatException('unknown action type ${json['type']}'),
      };
    } on ArgumentError catch (e) {
      // Constructor validation failed: the stored data is not a valid action.
      throw FormatException('invalid action: ${e.message}');
    }
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

  static List<int> _uids(Map<String, Object?> json) {
    final value = json['uids'];
    if (value is! List || value.any((v) => v is! int || v < 1)) {
      throw const FormatException('uids must be a list of UIDs');
    }
    return value.cast<int>();
  }

  static List<String> _strings(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! List || value.any((v) => v is! String)) {
      throw FormatException('$key must be a list of strings');
    }
    return value.cast<String>();
  }
}

/// An action on messages identified by UID in one folder.
///
/// Records the folder's UIDVALIDITY when the action was taken: if the
/// server has since reset the folder, the same UIDs may name different
/// messages, so the action must not be replayed.
sealed class UidAction extends OutboxAction {
  UidAction({
    required this.mailboxId,
    required this.uidValidity,
    required List<int> uids,
  }) : uids = List.unmodifiable(uids) {
    if (this.uids.isEmpty || this.uids.any((u) => u < 1)) {
      throw ArgumentError('UIDs must be at least 1');
    }
    if (uidValidity < 1) throw ArgumentError('UIDVALIDITY must be at least 1');
  }

  final int mailboxId;
  final int uidValidity;
  final List<int> uids;

  Map<String, Object?> get _common => {
    'mailboxId': mailboxId,
    'uidValidity': uidValidity,
    'uids': uids,
  };
}

/// Add and/or remove flags (read, flagged...).
final class SetFlagsAction extends UidAction {
  SetFlagsAction({
    required super.mailboxId,
    required super.uidValidity,
    required super.uids,
    List<String> add = const [],
    List<String> remove = const [],
  }) : add = List.unmodifiable(add),
       remove = List.unmodifiable(remove) {
    if (add.isEmpty && remove.isEmpty) throw ArgumentError('nothing to change');
  }

  final List<String> add;
  final List<String> remove;

  @override
  Map<String, Object?> toJson() => {
    'type': 'setFlags',
    ..._common,
    'add': add,
    'remove': remove,
  };
}

/// Move messages to another folder (archive, sort into a folder...).
final class MoveAction extends UidAction {
  MoveAction({
    required super.mailboxId,
    required super.uidValidity,
    required super.uids,
    required this.targetMailboxId,
  }) {
    if (mailboxId == targetMailboxId) {
      throw ArgumentError('source and target are the same folder');
    }
  }

  final int targetMailboxId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'move',
    ..._common,
    'targetMailboxId': targetMailboxId,
  };
}

/// Delete messages: move them to Trash, or remove them for good when
/// they already are in Trash.
final class DeleteAction extends UidAction {
  DeleteAction({
    required super.mailboxId,
    required super.uidValidity,
    required super.uids,
  });

  @override
  Map<String, Object?> toJson() => {'type': 'delete', ..._common};
}

/// Store a message (the entry's data) in a folder, e.g. a draft. Replays
/// skip it if a message with the same Message-ID is already there.
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

/// Remove an older copy of a draft from the Drafts folder, found by its
/// Message-ID. Only messages that are marked as drafts are removed, so a
/// real message can never be deleted this way.
final class RemoveDraftAction extends OutboxAction {
  RemoveDraftAction({required this.mailboxId, required this.messageId}) {
    if (messageId.isEmpty ||
        messageId.length > 998 ||
        messageId.contains(RegExp(r'[\s<>]'))) {
      throw ArgumentError.value(messageId, 'messageId', 'not a Message-ID');
    }
  }

  final int mailboxId;

  /// Without angle brackets.
  final String messageId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'removeDraft',
    'mailboxId': mailboxId,
    'messageId': messageId,
  };
}

/// Send a built message (the entry's data) and save it to Sent.
final class SendAction extends OutboxAction {
  SendAction({
    required this.from,
    required List<String> recipients,
    this.sentMailboxId,
    this.smtpAccepted = false,
  }) : recipients = List.unmodifiable(recipients) {
    if (this.recipients.isEmpty) throw ArgumentError('no recipients');
  }

  /// Envelope sender address.
  final String from;

  /// Envelope recipient addresses (To, Cc and Bcc).
  final List<String> recipients;
  final int? sentMailboxId;

  /// Set as soon as the SMTP server accepted the message, before saving to
  /// Sent, so a crash in between never sends the message twice.
  final bool smtpAccepted;

  SendAction markAccepted() => SendAction(
    from: from,
    recipients: recipients,
    sentMailboxId: sentMailboxId,
    smtpAccepted: true,
  );

  @override
  Map<String, Object?> toJson() => {
    'type': 'send',
    'from': from,
    'recipients': recipients,
    'sentMailboxId': sentMailboxId,
    'smtpAccepted': smtpAccepted,
  };
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
