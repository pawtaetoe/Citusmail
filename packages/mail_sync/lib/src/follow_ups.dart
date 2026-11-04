// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

/// "Remind me if no reply" on a message the user sent.
final class FollowUp {
  FollowUp({
    required this.messageId,
    required this.accountId,
    required this.due,
    required this.sentAt,
    this.subject = '',
    List<MailAddress> recipients = const [],
    this.inReplyTo,
    List<String> references = const [],
    this.returnedAt,
    this.notified = false,
  }) : recipients = List.unmodifiable(recipients),
       references = List.unmodifiable(references);

  /// The sent message's Message-ID, without brackets.
  final String messageId;
  final int accountId;

  /// When it comes back if nobody has answered (UTC).
  final DateTime due;

  /// When it was sent (or is due to go out, for "Send later").
  final DateTime sentAt;
  final String subject;

  /// Who it went to (To, then Cc).
  final List<MailAddress> recipients;

  /// Its own threading headers, to recognise answers to the conversation.
  final String? inReplyTo;
  final List<String> references;

  /// When it came back, marked "No reply yet"; null while waiting.
  final DateTime? returnedAt;

  /// Whether a notification was posted (or skipped) for its return.
  final bool notified;

  bool get returned => returnedAt != null;

  /// What [Replies] compares replies with.
  AwaitedMessage get awaited => AwaitedMessage(
    messageId: messageId,
    inReplyTo: inReplyTo,
    references: references,
    recipients: [for (final r in recipients) r.address],
  );

  FollowUp copyWith({
    DateTime? due,
    DateTime? sentAt,
    String? messageId,
    DateTime? returnedAt,
    bool clearReturned = false,
    bool? notified,
  }) => FollowUp(
    messageId: messageId ?? this.messageId,
    accountId: accountId,
    due: due ?? this.due,
    sentAt: sentAt ?? this.sentAt,
    subject: subject,
    recipients: recipients,
    inReplyTo: inReplyTo,
    references: references,
    returnedAt: clearReturned ? null : returnedAt ?? this.returnedAt,
    notified: notified ?? this.notified,
  );

  Map<String, Object?> toJson() => {
    'id': messageId,
    'account': accountId,
    'due': due.millisecondsSinceEpoch,
    'sent': sentAt.millisecondsSinceEpoch,
    'subject': subject,
    'to': [
      for (final r in recipients) [r.displayName, r.localPart, r.domain],
    ],
    'irt': ?inReplyTo,
    if (references.isNotEmpty) 'refs': references,
    'back': ?returnedAt?.millisecondsSinceEpoch,
    if (notified) 'notified': true,
  };

  static FollowUp? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], account = json['account'];
    final due = json['due'], sent = json['sent'];
    if (id is! String || id.isEmpty) return null;
    if (account is! int || due is! int || sent is! int) return null;
    DateTime utc(int ms) =>
        DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    final back = json['back'];
    return FollowUp(
      messageId: id,
      accountId: account,
      due: utc(due),
      sentAt: utc(sent),
      subject: json['subject'] is String ? json['subject'] as String : '',
      recipients: [
        for (final r in json['to'] is List ? json['to'] as List : const [])
          if (r is List &&
              r.length == 3 &&
              r[1] is String &&
              r[2] is String &&
              (r[0] == null || r[0] is String))
            MailAddress(
              displayName: r[0] as String?,
              localPart: r[1] as String,
              domain: r[2] as String,
            ),
      ],
      inReplyTo: json['irt'] is String ? json['irt'] as String : null,
      references: [
        for (final r in json['refs'] is List ? json['refs'] as List : const [])
          if (r is String) r,
      ],
      returnedAt: back is int ? utc(back) : null,
      notified: json['notified'] == true,
    );
  }

  @override
  String toString() =>
      'FollowUp($messageId due $due${returned ? ', returned' : ''})';
}

/// What a check found.
final class FollowUpCheck {
  const FollowUpCheck(this.returned, this.answered);

  static const none = FollowUpCheck([], []);

  /// Follow-ups that came back now: no reply by their time.
  final List<FollowUp> returned;

  /// Follow-ups ended quietly because a reply arrived.
  final List<FollowUp> answered;

  bool get isEmpty => returned.isEmpty && answered.isEmpty;
}

/// Follow-up reminders: "Remind me if no reply" on mail the user sent.
///
/// If nobody has answered by the chosen time, the sent message comes back
/// to the top of the inbox marked "No reply yet" (the app lists it there,
/// above the sections) until the user says it's done; a reply in the
/// conversation ends the follow-up quietly, also once it came back.
/// Answers are recognised by [Replies]: replies from the user themselves,
/// out-of-office and other automatic replies don't count.
///
/// Everything stays on this device, in the settings store (the background
/// check on Android reads and writes the same). Nothing changes on the
/// mail server. Checked after each sync, when the app comes to the
/// foreground, at the next due time, and by the background check.
final class FollowUpReminders {
  FollowUpReminders(this._store);

  final MailStore _store;

  static const _key = 'followUps.list';

  /// At most this many are kept (the oldest returned ones go first).
  static const maxKept = 500;

  /// Every follow-up, soonest due first.
  List<FollowUp> all() {
    final raw = _store.settings.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final j in decoded) ?FollowUp.fromJson(j)]..sort(_byDue);
    } on FormatException {
      return const [];
    }
  }

  /// Waiting for a reply, soonest due first.
  List<FollowUp> waiting() => [
    for (final f in all())
      if (!f.returned) f,
  ];

  /// Back with "No reply yet", most recent first.
  List<FollowUp> returned() => [
    for (final f in all())
      if (f.returned) f,
  ]..sort((a, b) => b.returnedAt!.compareTo(a.returnedAt!));

  FollowUp? find(String messageId) {
    for (final f in all()) {
      if (f.messageId == messageId) return f;
    }
    return null;
  }

  /// Sets (or replaces) a follow-up: it waits again until its time.
  FollowUp remind(FollowUp followUp) => _store.transaction(() {
    final f = followUp.copyWith(clearReturned: true, notified: false);
    _save([
      for (final o in all())
        if (o.messageId != f.messageId) o,
      f,
    ]);
    return f;
  });

  /// Puts back [followUp] exactly as it was (Undo).
  void restore(FollowUp followUp) => _store.transaction(() {
    _save([
      for (final o in all())
        if (o.messageId != followUp.messageId) o,
      followUp,
    ]);
  });

  /// Ends the follow-up of [messageId] ("Cancel", or "Done" once it came
  /// back). Returns it, for Undo.
  FollowUp? cancel(String messageId) => _store.transaction(() {
    final current = all();
    final found = current.where((f) => f.messageId == messageId).firstOrNull;
    if (found == null) return null;
    _save([
      for (final f in current)
        if (f.messageId != messageId) f,
    ]);
    return found;
  });

  /// The follow-up of a message that went out under another Message-ID
  /// ("Send later" changed or sent now), moved [shift] in time.
  void move(String from, String to, {Duration shift = Duration.zero}) =>
      _store.transaction(() {
        final f = cancel(from);
        if (f == null) return;
        restore(
          f.copyWith(
            messageId: to,
            due: f.due.add(shift),
            sentAt: f.sentAt.add(shift),
          ),
        );
      });

  /// When the next follow-up is due, if any is waiting.
  DateTime? nextDue() => waiting().firstOrNull?.due;

  /// Ends follow-ups that got a reply, and brings back those whose time
  /// came without one (marked to notify). Each comes back once: the check
  /// runs in one write transaction, so when the app and the background
  /// check look at the same time, only one of them gets it.
  FollowUpCheck check({DateTime? now}) => _store.transaction(() {
    final at = (now ?? DateTime.now()).toUtc();
    final current = all();
    if (current.isEmpty) return FollowUpCheck.none;
    final answered = _answered(current);
    final returned = <FollowUp>[];
    final kept = <FollowUp>[];
    for (final f in current) {
      if (answered.contains(f.messageId)) continue;
      if (!f.returned && !f.due.isAfter(at)) {
        final back = f.copyWith(returnedAt: f.due, notified: false);
        returned.add(back);
        kept.add(back);
      } else {
        kept.add(f);
      }
    }
    if (returned.isEmpty && answered.isEmpty) return FollowUpCheck.none;
    _save(kept);
    return FollowUpCheck(returned, [
      for (final f in current)
        if (answered.contains(f.messageId)) f,
    ]);
  });

  /// Returned follow-ups not yet notified, marked notified now (each is
  /// claimed once). The caller decides whether to post them.
  List<FollowUp> claimUnnotified() => _store.transaction(() {
    final current = all();
    final claimed = [
      for (final f in current)
        if (f.returned && !f.notified) f,
    ];
    if (claimed.isEmpty) return const <FollowUp>[];
    _save([for (final f in current) f.copyWith(notified: true)]);
    return claimed;
  });

  /// The sent message on this device (usually in the Sent folder), if it
  /// is there.
  StoredMessage? sentCopy(FollowUp f) {
    final sent = _store.mailboxes.bySpecialUse(f.accountId, SpecialUse.sent);
    for (final box in [
      ?sent,
      for (final b in _store.mailboxes.forAccount(f.accountId))
        if (b.id != sent?.id) b,
    ]) {
      final found = _store.messages.byMessageId(box.id, f.messageId);
      if (found.isNotEmpty) return found.first;
    }
    return null;
  }

  /// A follow-up for [m], a message the user sent, as stored: its
  /// recipients and threading headers.
  FollowUp forMessage(StoredMessage m, DateTime due) => FollowUp(
    messageId: m.messageId!,
    accountId: m.accountId,
    due: due.toUtc(),
    sentAt: (m.sentAt ?? m.receivedAt).toUtc(),
    subject: m.subject?.trim() ?? '',
    recipients: [
      ..._store.messages.addresses(m.id, 'to'),
      ..._store.messages.addresses(m.id, 'cc'),
    ],
    inReplyTo: m.inReplyTo,
    references: m.references,
  );

  /// Message-IDs of [followUps] that got an answer since they were sent,
  /// in any folder but Sent, Drafts and Junk.
  Set<String> _answered(List<FollowUp> followUps) {
    final own = {for (final a in _store.accounts.all()) a.email};
    final earliest = followUps
        .map((f) => f.sentAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final awaited = {for (final f in followUps) f.messageId: f.awaited};
    final found = <String>{};
    for (final account in _store.accounts.all()) {
      for (final box in _store.mailboxes.forAccount(account.id)) {
        if (const {
          SpecialUse.sent,
          SpecialUse.drafts,
          SpecialUse.junk,
        }.contains(box.specialUse)) {
          continue;
        }
        for (final m in _store.messages.threadedSince(box.id, earliest)) {
          for (final f in followUps) {
            if (found.contains(f.messageId)) continue;
            if (!m.receivedAt.isAfter(f.sentAt)) continue;
            final sent = awaited[f.messageId]!;
            // Headers are read only for a likely answer.
            if (!Replies.answers(_candidate(m), sent, ownAddresses: own)) {
              continue;
            }
            final candidate = _candidate(
              m,
              headers: _store.messages.headers(m.id),
            );
            if (Replies.answers(candidate, sent, ownAddresses: own)) {
              found.add(f.messageId);
            }
          }
        }
      }
    }
    return found;
  }

  static ReplyCandidate _candidate(
    StoredMessage m, {
    Map<String, List<String>> headers = const {},
  }) => ReplyCandidate(
    messageId: m.messageId,
    inReplyTo: m.inReplyTo,
    references: m.references,
    from: m.from,
    subject: m.subject,
    headers: headers,
  );

  void _save(List<FollowUp> followUps) {
    var kept = followUps;
    if (kept.length > maxKept) {
      // The oldest returned ones go first, then the furthest due.
      final returned = [
        for (final f in kept)
          if (f.returned) f,
      ]..sort((a, b) => a.returnedAt!.compareTo(b.returnedAt!));
      final drop = {
        for (final f in returned.take(kept.length - maxKept)) f.messageId,
      };
      kept = [
        for (final f in kept)
          if (!drop.contains(f.messageId)) f,
      ]..sort(_byDue);
      if (kept.length > maxKept) kept = kept.sublist(0, maxKept);
    }
    if (kept.isEmpty) {
      _store.settings.delete(_key);
      return;
    }
    _store.settings.write(_key, jsonEncode([for (final f in kept) f.toJson()]));
  }

  static int _byDue(FollowUp a, FollowUp b) {
    final byDue = a.due.compareTo(b.due);
    return byDue != 0 ? byDue : a.messageId.compareTo(b.messageId);
  }
}
