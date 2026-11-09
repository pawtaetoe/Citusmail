// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'mail_actions.dart';

/// Applies the user's custom-folder rules to new inbox mail: matching
/// messages are moved into their folder on the server (through the
/// outbox), so every device and mail app sees the result.
///
/// - Only mail received at or after a rule's start moves, with
///   [clockTolerance]: arrival times come from the server's clock (to the
///   second), which may differ from this device's.
/// - A message a rule already moved is never moved again (by Message-ID),
///   so one the user brings back to the inbox stays there. Messages
///   without a Message-ID are left alone for that reason.
/// - The oldest matching rule wins.
/// - Each pass looks only at mail that arrived since the last one, unless
///   the rules changed ([InboxPass]).
final class FolderRuleApplier {
  FolderRuleApplier(this._store) : _actions = MailActions(_store);

  final MailStore _store;
  final MailActions _actions;

  static const clockTolerance = Duration(minutes: 10);

  /// Moves matching inbox messages of [account]; returns how many. With
  /// [everything], every message since the oldest rule's start is looked
  /// at, not only mail that arrived since the last pass.
  int apply(Account account, {bool everything = false}) {
    final rules = _store.folderRules.forAccount(account.id);
    if (rules.isEmpty) return 0;
    final inbox = _store.mailboxes.inbox(account.id);
    if (inbox == null) return 0;
    final needsRecipients = rules.any((r) => r.field == RuleField.toAddress);

    final earliest = rules.map(_start).reduce((a, b) => a.isBefore(b) ? a : b);
    final pass = InboxPass.start(
      _store,
      'rules',
      inbox,
      InboxPass.digest([
        for (final r in rules)
          [
            r.id,
            r.mailboxId,
            r.field.name,
            r.value,
            r.appliesFrom.millisecondsSinceEpoch,
          ],
      ]),
      everything: everything,
    );
    final moves = <int, List<StoredMessage>>{};
    for (final message in pass.messages(earliest)) {
      final messageId = message.messageId;
      if (messageId == null ||
          _store.folderRules.wasMoved(account.id, messageId)) {
        continue;
      }
      final recipients = needsRecipients
          ? [
              ..._store.messages.addresses(message.id, 'to'),
              ..._store.messages.addresses(message.id, 'cc'),
            ]
          : const <MailAddress>[];
      for (final rule in rules) {
        if (rule.mailboxId == inbox.id) continue;
        if (message.receivedAt.isBefore(_start(rule))) continue;
        if (RuleMatcher.matches(rule, message, recipients)) {
          moves.putIfAbsent(rule.mailboxId, () => []).add(message);
          break;
        }
      }
    }

    var moved = 0;
    for (final MapEntry(key: mailboxId, value: messages) in moves.entries) {
      final target = _store.mailboxes.byId(mailboxId);
      if (target == null || !target.selectable) continue;
      _store.transaction(() {
        _actions.move(messages, target);
        for (final m in messages) {
          _store.folderRules.recordMoved(account.id, m.messageId!);
        }
      });
      moved += messages.length;
    }
    pass.finish();
    return moved;
  }

  static DateTime _start(FolderRule rule) =>
      rule.appliesFrom.subtract(clockTolerance);
}

/// Reads an inbox page by page, newest first.
abstract final class InboxScan {
  /// Messages in [inbox] received at or after [earliest].
  static Iterable<StoredMessage> since(
    MailStore store,
    StoredMailbox inbox,
    DateTime earliest,
  ) sync* {
    StoredMessage? before;
    while (true) {
      final page = store.messages.list(
        MessageQuery(mailboxIds: [inbox.id], before: before, limit: 500),
      );
      for (final message in page) {
        if (message.receivedAt.isBefore(earliest)) return;
        yield message;
      }
      if (page.length < 500) return;
      before = page.last;
    }
  }
}

/// Which inbox mail one pass of the blocks, the folder rules or the
/// Screener has to look at.
///
/// The first pass, and any pass after what it applies changed (its
/// [fingerprint]: a rule, block or decision added, changed or removed),
/// looks at every message since the oldest start, as before. Every other
/// pass looks only at mail that arrived since the last one: messages with
/// a UID above the highest one it saw. A pass with `everything` (older
/// mail was just downloaded) or after the server renumbered the inbox
/// (UIDVALIDITY) looks at everything again. The mark is kept in the
/// settings table, per inbox and kind of pass.
final class InboxPass {
  InboxPass._(
    this._store,
    this._key,
    this._value,
    this.inbox,
    this._seen,
    this._highest,
    this.everything,
  );

  /// Starts a pass of [kind] over [inbox] for what [fingerprint] sums up.
  factory InboxPass.start(
    MailStore store,
    String kind,
    StoredMailbox inbox,
    String fingerprint, {
    bool everything = false,
  }) {
    final key = 'scan.$kind.${inbox.id}';
    final prefix = '${inbox.syncState.uidValidity}:$fingerprint:';
    final mark = store.settings.read(key);
    final seen = mark != null && mark.startsWith(prefix)
        ? int.tryParse(mark.substring(prefix.length))
        : null;
    return InboxPass._(
      store,
      key,
      prefix,
      inbox,
      seen,
      store.messages.highestUid(inbox.id) ?? 0,
      everything || seen == null,
    );
  }

  final MailStore _store;
  final String _key;
  final String _value;
  final StoredMailbox inbox;
  final int? _seen;

  /// Whether this pass looks at every message since the start, rather
  /// than only at mail that arrived since the last pass.
  final bool everything;

  /// The highest UID when the pass started.
  final int _highest;

  /// The messages to look at, received at or after [earliest]. With
  /// [everything], newest first; else in the order they arrived.
  Iterable<StoredMessage> messages(DateTime earliest) sync* {
    if (everything) {
      yield* InboxScan.since(_store, inbox, earliest);
      return;
    }
    for (final uid in _store.messages.uidsAbove(inbox.id, _seen!)) {
      if (uid > _highest) break;
      final message = _store.messages.byUid(inbox.id, uid);
      if (message != null && !message.receivedAt.isBefore(earliest)) {
        yield message;
      }
    }
  }

  /// Remembers that every message up to the highest UID at the start
  /// was looked at.
  void finish() => _store.settings.write(_key, '$_value$_highest');

  /// A short digest of [parts], for [fingerprint]s.
  static String digest(Iterable<Object?> parts) =>
      sha1.convert(utf8.encode(jsonEncode([...parts]))).toString();
}

/// Whether a message matches a rule.
abstract final class RuleMatcher {
  static bool matches(
    FolderRule rule,
    StoredMessage message,
    List<MailAddress> recipients,
  ) {
    final value = rule.value;
    return switch (rule.field) {
      RuleField.fromAddress => message.from?.address.toLowerCase() == value,
      RuleField.fromDomain => switch (message.from?.domain.toLowerCase()) {
        final domain? => domain == value || domain.endsWith('.$value'),
        null => false,
      },
      RuleField.toAddress => recipients.any(
        (a) => a.address.toLowerCase() == value,
      ),
      RuleField.subject => (message.subject ?? '').toLowerCase().contains(
        value,
      ),
    };
  }
}

/// Makes the server name for a new folder the user named, following the
/// account's layout: the folder separator, and the "INBOX." prefix that
/// cPanel-style servers require for every folder.
abstract final class FolderNames {
  /// The encoded name for [name] ("Projects/2026" makes a subfolder), or
  /// throws [ArgumentError] if it cannot be a folder name.
  static String newFolder(List<StoredMailbox> existing, String name) {
    final parts = name.split('/').map((p) => p.trim()).toList();
    if (parts.any((p) => p.isEmpty || p.length > 100) ||
        parts.any((p) => p.contains(RegExp(r'[\x00-\x1F\x7F%*"\\]')))) {
      throw ArgumentError.value(name, 'name', 'not a usable folder name');
    }
    if (parts.length == 1 && parts.single.toUpperCase() == 'INBOX') {
      throw ArgumentError.value(name, 'name', 'INBOX already exists');
    }
    final inbox = existing.where((m) => m.isInbox).firstOrNull;
    final delimiter =
        inbox?.delimiter ??
        existing.map((m) => m.delimiter).nonNulls.firstOrNull ??
        '/';
    if (parts.any((p) => p.contains(delimiter))) {
      throw ArgumentError.value(
        name,
        'name',
        'contains the folder separator "$delimiter"',
      );
    }
    // Everything already lives under INBOX: new folders must too.
    final others = existing.where((m) => !m.isInbox).toList();
    final inboxPrefix = 'INBOX$delimiter';
    final underInbox =
        others.isNotEmpty &&
        others.every(
          (m) =>
              m.encodedName.toUpperCase().startsWith(inboxPrefix.toUpperCase()),
        );
    final encoded = parts.map(MailboxNameCodec.encode).join(delimiter);
    return underInbox ? '$inboxPrefix$encoded' : encoded;
  }
}
