// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_ai/mail_ai.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

/// The only changes "Ask AI to tidy" can propose: each one reversible
/// with Undo, and each one something the list's own buttons do. Nothing
/// sends, forwards, deletes, unsubscribes, blocks or makes rules.
enum TidyKind {
  archive('archive'),
  move('move_to_folder'),
  markRead('mark_read'),
  markUnread('mark_unread'),
  pin('pin'),
  unpin('unpin'),
  snooze('snooze');

  const TidyKind(this.wire);

  /// The name in the model's answer.
  final String wire;

  static TidyKind? byWire(Object? name) =>
      values.where((k) => k.wire == name).firstOrNull;

  /// Whether the message leaves the list (so it can be in one such
  /// change only).
  bool get removes => this == archive || this == move || this == snooze;
}

/// The emails a request works on: the selected ones, or the list the
/// user is in, at most [cap] of them. Each has a short reference ("m12")
/// that the model names it by.
final class TidyCandidates {
  TidyCandidates(List<StoredMessage> messages, {bool trimmed = false})
    : messages = List.unmodifiable(messages.take(cap)),
      trimmed = trimmed || messages.length > cap;

  /// The most emails one request looks at.
  static const cap = 200;

  final List<StoredMessage> messages;

  /// Whether there were more than [cap] (only the first were kept).
  final bool trimmed;

  bool get isEmpty => messages.isEmpty;
  int get length => messages.length;

  late final Map<String, StoredMessage> _byRef = {
    for (final (i, m) in messages.indexed) 'm${i + 1}': m,
  };

  late final Map<int, String> _refOf = {
    for (final MapEntry(:key, :value) in _byRef.entries) value.id: key,
  };

  String refOf(StoredMessage m) => _refOf[m.id]!;

  StoredMessage? byRef(Object? ref) => ref is String ? _byRef[ref] : null;
}

/// One change of a plan: [kind] for [messages] (into [folder] for a move,
/// until [until] for a snooze).
final class TidyStep {
  const TidyStep(this.kind, this.messages, {this.folder, this.until});

  final TidyKind kind;
  final List<StoredMessage> messages;

  /// For [TidyKind.move]: the folder's name as the user's folder list
  /// shows it; each message goes to the folder of that name in its own
  /// account ([TidyPlanner.folderIn]).
  final String? folder;

  /// For [TidyKind.snooze], local time.
  final DateTime? until;

  TidyStep withMessages(List<StoredMessage> messages) =>
      TidyStep(kind, messages, folder: folder, until: until);
}

/// What the model proposed, checked: only known changes, only for the
/// candidates, only into folders that exist, only for sane times.
final class TidyPlan {
  const TidyPlan(this.steps, {this.note, this.leftOut = 0});

  static const empty = TidyPlan([]);

  final List<TidyStep> steps;

  /// The model's one-sentence comment (plain text, shortened), such as
  /// why nothing matched.
  final String? note;

  /// How many of the proposed changes were dropped: unknown changes (a
  /// delete, say), emails that aren't among the candidates, folders that
  /// don't exist, impossible times.
  final int leftOut;

  bool get isEmpty => steps.isEmpty;
}

/// Builds the request for "Ask AI to tidy" and checks the answer.
///
/// The request carries the user's words, the folder names, and for each
/// candidate only its sender, subject and date (through [MailPrompt], as
/// untrusted data) plus what the app knows about it: folder, category,
/// read, pinned, snoozed. Never the text of any email.
final class TidyPlanner {
  TidyPlanner(
    this._store, {
    required this.now,
    bool Function(StoredMessage m)? canSnooze,
    DateTime? Function(StoredMessage m)? snoozedUntil,
  }) : _canSnooze = canSnooze ?? _inboxWithId(_store),
       _snoozedUntil = snoozedUntil ?? ((_) => null);

  final MailStore _store;

  /// The local time the request is made (for "until Monday", "older than
  /// a month").
  final DateTime now;
  final bool Function(StoredMessage m) _canSnooze;
  final DateTime? Function(StoredMessage m) _snoozedUntil;

  /// How long the user's words may be.
  static const maxRequestChars = 600;

  /// How long the model's note may be.
  static const maxNoteChars = 240;

  /// A snooze must be at least this far ahead, and at most [maxSnooze].
  static const minimumAhead = Duration(minutes: 5);
  static const maxSnooze = Duration(days: 366);

  /// A date without a time means this hour (as "Tomorrow" in Snooze).
  static const morning = 8;

  static bool Function(StoredMessage) _inboxWithId(MailStore store) =>
      (m) =>
          m.messageId != null &&
          (store.mailboxes.byId(m.mailboxId)?.isInbox ?? false);

  // ------------------------------------------------------------- folders

  /// Folders the model may move mail into: real folders of the
  /// candidates' accounts, not Trash or Junk (moving there would be a
  /// delete by another name), Drafts, Sent, views like Gmail's Starred,
  /// or the app's own data folder.
  static bool canMoveInto(StoredMailbox box) =>
      box.selectable &&
      !box.isAppData &&
      !box.isView &&
      switch (box.specialUse) {
        SpecialUse.trash ||
        SpecialUse.junk ||
        SpecialUse.drafts ||
        SpecialUse.sent => false,
        _ => true,
      };

  /// A folder as the model sees it: "Inbox", or its path with "/".
  static String folderName(StoredMailbox box) => box.isInbox
      ? 'Inbox'
      : switch (box.delimiter) {
          final d? when d != '/' => box.name.replaceAll(d, '/'),
          _ => box.name,
        };

  /// The folder names offered for [candidates]: Inbox first, then in
  /// order, once each.
  List<String> folderNames(TidyCandidates candidates) {
    final names = <String>{};
    for (final accountId in {
      for (final m in candidates.messages) m.accountId,
    }) {
      final boxes = _store.mailboxes.forAccount(accountId);
      for (final box in [
        ...boxes.where((b) => b.isInbox),
        ...boxes.where((b) => !b.isInbox),
      ]) {
        if (canMoveInto(box)) names.add(folderName(box));
      }
    }
    return names.toList();
  }

  /// The folder called [name] in [accountId] that mail may be moved into.
  StoredMailbox? folderIn(int accountId, String name) {
    final wanted = name.trim().toLowerCase();
    for (final box in _store.mailboxes.forAccount(accountId)) {
      if (canMoveInto(box) && folderName(box).toLowerCase() == wanted) {
        return box;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- request

  static const _task = '''
You help someone tidy their email. They say what they want in their own words; you propose changes, which the app shows them as a checklist. Nothing happens until they confirm.

You can only propose these changes, each for a list of emails named by their Ref:
- "archive": move to the account's Archive.
- "move_to_folder": move to one of the folders listed in the request; give its exact name in "folder".
- "mark_read" and "mark_unread".
- "pin" and "unpin" (pinned emails stay at the top; also called starring or flagging).
- "snooze": hide from the inbox until a time, given in "until" as YYYY-MM-DD or YYYY-MM-DDTHH:MM in the person's local time. Only for emails whose Folder is Inbox.
Nothing else is possible: no deleting, sending, replying, forwarding, unsubscribing, blocking or rules. If the request asks for any of that, leave it out and say so in "note".

Each email block holds only the email's sender, date (UTC) and subject, which other people wrote, and then lines the app added: Ref, Folder, Category, Read, Pinned, Snoozed until, Attachments. You never see the text of the emails.

Propose only what the request asks for, and only for emails it clearly matches. Use only Refs of the emails given. List each change once, with all its emails, and set "folder" and "until" to null where they don't apply. If nothing matches, give no changes and say why in "note". Keep "note" to one short, plain sentence, or empty.''';

  /// What the answer must look like (strict: every object closed, every
  /// field required).
  static final schema = AiJsonSchema(
    name: 'tidy_plan',
    schema: {
      'type': 'object',
      'additionalProperties': false,
      'required': ['actions', 'note'],
      'properties': {
        'actions': {
          'type': 'array',
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['action', 'ids', 'folder', 'until'],
            'properties': {
              'action': {
                'type': 'string',
                'enum': [for (final k in TidyKind.values) k.wire],
              },
              'ids': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'The Refs of the emails, like "m3".',
              },
              'folder': {
                'type': ['string', 'null'],
                'description': 'For move_to_folder: a folder name listed.',
              },
              'until': {
                'type': ['string', 'null'],
                'description':
                    'For snooze: YYYY-MM-DD or YYYY-MM-DDTHH:MM, local time.',
              },
            },
          },
        },
        'note': {'type': 'string'},
      },
    },
  );

  /// The request to [model] for the user's [words] about [candidates].
  AiRequest request({
    required String model,
    required String words,
    required TidyCandidates candidates,
    MailPrompt? prompt,
  }) {
    final mail = prompt ?? MailPrompt();
    final folders = folderNames(candidates);
    final text = words.trim();
    final request = StringBuffer()
      ..writeln('Now: ${_describeNow(now)}.')
      ..writeln(
        'Folders to move to: ${jsonEncode([for (final f in folders) MailPrompt.neutralise(f)])}',
      )
      ..writeln()
      ..writeln('What the person asks:')
      ..write(
        text.length <= maxRequestChars
            ? text
            : text.substring(0, maxRequestChars),
      );
    return AiRequest(
      model: model,
      system: mail.system(_task),
      messages: [
        mail.userMessage([
          for (final m in candidates.messages) _promptMail(m, candidates),
        ], request.toString()),
      ],
      maxOutputTokens: 4096,
      jsonSchema: schema,
      effort: AiEffort.low,
    );
  }

  PromptMail _promptMail(StoredMessage m, TidyCandidates candidates) {
    final folder = _store.mailboxes.byId(m.mailboxId);
    final until = _snoozedUntil(m);
    return PromptMail(
      from: _sender(m.from),
      date: m.sentAt ?? m.receivedAt,
      subject: m.subject,
      body: [
        'Ref: ${candidates.refOf(m)}',
        'Folder: ${folder == null ? '?' : folderName(folder)}',
        'Category: ${_category(m.category)}',
        'Read: ${m.flags.seen ? 'yes' : 'no'}',
        'Pinned: ${m.flags.flagged ? 'yes' : 'no'}',
        if (until != null) 'Snoozed until: ${_local(until)}',
        if (m.hasAttachments) 'Attachments: yes',
      ].join('\n'),
    );
  }

  static String _sender(MailAddress? from) => switch (from) {
    null => '(unknown)',
    MailAddress(:final displayName?) when displayName.isNotEmpty =>
      '$displayName <${from.address}>',
    _ => from.address,
  };

  static String _category(MessageCategory c) => switch (c) {
    MessageCategory.general => 'personal or other',
    MessageCategory.newsletters => 'newsletter',
    MessageCategory.notifications => 'notification',
    MessageCategory.codes => 'verification code',
  };

  static const _days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _local(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${_two(l.month)}-${_two(l.day)} '
        '${_two(l.hour)}:${_two(l.minute)}';
  }

  static String _describeNow(DateTime now) {
    final l = now.toLocal();
    final offset = l.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    return '${_days[l.weekday - 1]} ${_local(l)} local time '
        '(UTC$sign${_two(minutes ~/ 60)}:${_two(minutes % 60)})';
  }

  // -------------------------------------------------------------- answer

  /// The answer as a checked plan. Throws [AiException] with
  /// [AiProblem.badResponse] when it isn't a plan at all.
  TidyPlan plan(AiResponse response, TidyCandidates candidates) {
    final json = answerJson(response);
    if (json == null) {
      throw const AiException(AiProblem.badResponse, 'not a plan');
    }
    return check(json, candidates);
  }

  /// The JSON object in [response]: its text (also inside a ```json
  /// fence), or the input of a tool call.
  static Map<String, Object?>? answerJson(AiResponse response) {
    if (response.json case final json?) return json;
    final text = response.text;
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final value = jsonDecode(text.substring(start, end + 1));
        if (value is Map<String, Object?>) return value;
      } on FormatException {
        // Not JSON: below.
      }
    }
    for (final call in response.toolCalls) {
      if (call.input['actions'] is List) return call.input;
    }
    return null;
  }

  /// Checks a proposed plan against [candidates] and the mailbox as it is
  /// now. Whatever doesn't fit is left out (and counted): changes the app
  /// doesn't offer, emails that aren't candidates, folders that don't
  /// exist (or Trash and Junk), snoozes in the past or more than a year
  /// ahead. Changes that are already so (marking read mail read) are
  /// dropped silently; an email leaves the list in one change at most,
  /// and gets one of read/unread and one of pin/unpin.
  TidyPlan check(Map<String, Object?> json, TidyCandidates candidates) {
    var leftOut = 0;
    final steps = <TidyStep>[];
    final leaving = <int>{};
    final readSet = <int>{};
    final pinSet = <int>{};
    final actions = json['actions'];
    for (final item in actions is List ? actions : const <Object?>[]) {
      if (item is! Map) {
        leftOut++;
        continue;
      }
      final kind = TidyKind.byWire(item['action']);
      final ids = item['ids'];
      if (kind == null || ids is! List) {
        leftOut++;
        continue;
      }
      String? folder;
      DateTime? until;
      if (kind == TidyKind.move) {
        final name = item['folder'];
        folder = name is String ? name.trim() : null;
        if (folder == null ||
            !candidates.messages.any(
              (m) => folderIn(m.accountId, folder!) != null,
            )) {
          leftOut++;
          continue;
        }
      }
      if (kind == TidyKind.snooze) {
        until = snoozeTime(item['until']);
        if (until == null) {
          leftOut++;
          continue;
        }
      }
      final messages = <StoredMessage>[];
      for (final ref in ids) {
        final m = candidates.byRef(ref);
        if (m == null) {
          leftOut++;
          continue;
        }
        if (!_possible(kind, m, folder)) {
          leftOut++;
          continue;
        }
        if (!_changes(kind, m, folder)) continue;
        final claimed = switch (kind) {
          TidyKind.archive || TidyKind.move || TidyKind.snooze => leaving,
          TidyKind.markRead || TidyKind.markUnread => readSet,
          TidyKind.pin || TidyKind.unpin => pinSet,
        };
        if (!claimed.add(m.id)) continue;
        messages.add(m);
      }
      if (messages.isEmpty) continue;
      // The same change twice: one step.
      final same = steps.indexWhere(
        (s) =>
            s.kind == kind &&
            s.folder?.toLowerCase() == folder?.toLowerCase() &&
            s.until == until,
      );
      if (same >= 0) {
        steps[same] = steps[same].withMessages([
          ...steps[same].messages,
          ...messages,
        ]);
      } else {
        steps.add(TidyStep(kind, messages, folder: folder, until: until));
      }
    }
    return TidyPlan(steps, note: _note(json['note']), leftOut: leftOut);
  }

  /// Whether [kind] can be done to [m] at all.
  bool _possible(TidyKind kind, StoredMessage m, String? folder) =>
      switch (kind) {
        TidyKind.archive =>
          MailActions.archiveFolder(_store, m.accountId) != null,
        TidyKind.move => folderIn(m.accountId, folder!) != null,
        TidyKind.snooze => _canSnooze(m),
        _ => true,
      };

  /// Whether [kind] would change [m] (archiving archived mail doesn't).
  bool _changes(TidyKind kind, StoredMessage m, String? folder) =>
      switch (kind) {
        TidyKind.archive =>
          MailActions.archiveFolder(_store, m.accountId)?.id != m.mailboxId,
        TidyKind.move => folderIn(m.accountId, folder!)?.id != m.mailboxId,
        TidyKind.markRead => !m.flags.seen,
        TidyKind.markUnread => m.flags.seen,
        TidyKind.pin => !m.flags.flagged,
        TidyKind.unpin => m.flags.flagged,
        TidyKind.snooze => true,
      };

  /// [value] as a snooze time: "YYYY-MM-DD" (at [morning]) or a date and
  /// time, local unless it says otherwise; null unless it is a real time
  /// between [minimumAhead] and [maxSnooze] from [now].
  DateTime? snoozeTime(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    final dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
    DateTime? at;
    if (dateOnly != null) {
      final [y, m, d] = [for (var i = 1; i <= 3; i++) int.parse(dateOnly[i]!)];
      at = DateTime(y, m, d, morning);
      // Not a real day (February 30th rolls over).
      if (at.month != m || at.day != d) return null;
    } else if (RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}').hasMatch(text)) {
      at = DateTime.tryParse(text)?.toLocal();
    }
    if (at == null) return null;
    final local = now.toLocal();
    if (!at.isAfter(local.add(minimumAhead))) return null;
    if (at.isAfter(local.add(maxSnooze))) return null;
    return at;
  }

  static String? _note(Object? value) {
    if (value is! String) return null;
    final line = MailPrompt.neutralise(value)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.isEmpty) return null;
    return line.length <= maxNoteChars
        ? line
        : '${line.substring(0, maxNoteChars - 1)}…';
  }
}
