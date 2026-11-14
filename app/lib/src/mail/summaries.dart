// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import '../services/ai_assistant.dart';

/// What to summarise: the open email, or its whole conversation.
enum SummaryScope { message, conversation }

/// A tap on "Summarise" (each tap a new one, so the same message can be
/// asked for again).
final class SummaryRequest {
  SummaryRequest(this.messageId, this.scope);

  final int messageId;
  final SummaryScope scope;
}

/// A finished summary, kept on this device (encrypted, with the mail) so
/// reopening the email doesn't send it again.
final class SavedSummary {
  const SavedSummary({
    required this.text,
    required this.provider,
    required this.recipient,
    required this.model,
    required this.at,
    required this.emails,
  });

  final String text;
  final AiProviderKind provider;

  /// Who it was sent to ("Anthropic", or the endpoint's host).
  final String recipient;
  final String model;
  final DateTime at;

  /// How many emails it covers.
  final int emails;

  static SavedSummary? fromJson(String? json) {
    if (json == null) return null;
    try {
      final map = jsonDecode(json) as Map<String, Object?>;
      return SavedSummary(
        text: map['text']! as String,
        provider: AiProviderKind.byId(map['provider'] as String?)!,
        recipient: map['recipient']! as String,
        model: map['model']! as String,
        at: DateTime.fromMillisecondsSinceEpoch(map['at']! as int),
        emails: map['emails'] as int? ?? 1,
      );
    } on Object {
      return null;
    }
  }

  String toJson() => jsonEncode({
    'text': text,
    'provider': provider.id,
    'recipient': recipient,
    'model': model,
    'at': at.millisecondsSinceEpoch,
    'emails': emails,
  });
}

/// A summary's parts, from the fixed format [MessageSummaries.task] asks
/// for. Also works on a summary still being written.
final class SummaryParts {
  const SummaryParts(this.overview, this.sections);

  /// One or two sentences.
  final String overview;

  /// "Key points", "Dates", "Amounts", "Asked of you": each with its
  /// lines, in that order, only those with something in them.
  final List<({String title, List<String> items})> sections;

  static const titles = ['Key points', 'Dates', 'Amounts', 'Asked of you'];

  static SummaryParts parse(String text) {
    final overview = StringBuffer();
    final items = <String, List<String>>{};
    String? current;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final heading = RegExp(
        r'^\**\s*(Summary|Key points|Dates|Amounts|Asked of you)\s*\**\s*:\s*\**\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (heading != null) {
        final name = heading[1]!.toLowerCase();
        current = name == 'summary'
            ? null
            : titles.firstWhere((t) => t.toLowerCase() == name);
        final rest = heading[2]!.trim();
        if (rest.isNotEmpty) {
          if (current == null) {
            overview.write('${overview.isEmpty ? '' : ' '}$rest');
          } else if (!_none(rest)) {
            items.putIfAbsent(current, () => []).add(rest);
          }
        }
        continue;
      }
      final item = line.replaceFirst(RegExp(r'^([-*•]|\d+[.)])\s*'), '');
      if (current == null) {
        overview.write('${overview.isEmpty ? '' : ' '}$item');
      } else if (item.isNotEmpty && !_none(item)) {
        items.putIfAbsent(current, () => []).add(item);
      }
    }
    return SummaryParts(overview.toString(), [
      for (final t in titles)
        if (items[t] case final lines? when lines.isNotEmpty)
          (title: t, items: lines),
    ]);
  }

  /// "None", "-", "n/a": nothing.
  static bool _none(String text) => RegExp(
    r'^(none|nothing|n/?a|-|—)\.?$',
    caseSensitive: false,
  ).hasMatch(text.trim());
}

/// "Summarise" in the reader: one email or its conversation, sent to the
/// provider the user chose for summaries, streamed back, and kept on the
/// device so it is never paid for twice.
///
/// What is sent is built by [MailPrompt]: only the emails summarised
/// (their senders, recipients, dates, subjects, text, and the names of
/// attached files, never the files), as data the model is told not to
/// take instructions from.
final class MessageSummaries {
  MessageSummaries(this._store, this._ai, {required this.loadBody});

  final MailStore _store;
  final AiAssistant _ai;

  /// Downloads a message's body that isn't on the device yet (from the
  /// user's own mail server).
  final Future<void> Function(int messageId) loadBody;

  static final feature = AiFeatures.summaries;

  /// The last "Summarise" tapped: the reader shows the summary.
  final requests = ValueNotifier<SummaryRequest?>(null);

  /// Whether summaries are on (and set up): otherwise no button shows.
  bool get available => _ai.isOn(feature.id);

  /// The conversation [message] is in, oldest first (itself alone if it
  /// answers nothing and nothing answers it).
  List<StoredMessage> conversationOf(StoredMessage message) =>
      _store.messages.conversation(message);

  void ask(StoredMessage message, SummaryScope scope) =>
      requests.value = SummaryRequest(message.id, scope);

  static const _indexKey = 'ai.summaries';
  static const _prefix = 'ai.summary.';

  /// How many summaries are kept; the oldest go first.
  static const keep = 300;

  /// The emails [scope] covers.
  List<StoredMessage> _emails(StoredMessage message, SummaryScope scope) =>
      scope == SummaryScope.message ? [message] : conversationOf(message);

  /// Where a summary of exactly [emails] is kept: the same emails (by
  /// Message-ID) give the same key, so a new reply makes a new summary.
  static String _key(SummaryScope scope, List<StoredMessage> emails) {
    final ids = [
      for (final m in emails) '${m.accountId}:${m.messageId ?? 'row${m.id}'}',
    ]..sort();
    final hash = sha256.convert(utf8.encode(ids.join('\n'))).toString();
    return '$_prefix${scope.name[0]}.${hash.substring(0, 24)}';
  }

  /// The kept summary of [message] (or its conversation), if any.
  SavedSummary? saved(StoredMessage message, SummaryScope scope) =>
      SavedSummary.fromJson(
        _store.settings.read(_key(scope, _emails(message, scope))),
      );

  List<String> _index() {
    try {
      return [
        for (final k in jsonDecode(
          _store.settings.read(_indexKey) ?? '[]',
        ) as List<Object?>)
          if (k is String) k,
      ];
    } on Object {
      return [];
    }
  }

  void _keep(String key, SavedSummary summary) {
    _store.settings.write(key, summary.toJson());
    final index = _index()
      ..remove(key)
      ..add(key);
    while (index.length > keep) {
      _store.settings.delete(index.removeAt(0));
    }
    _store.settings.write(_indexKey, jsonEncode(index));
  }

  /// Removes every kept summary ("Forget saved summaries", or turning
  /// summaries off).
  void forgetAll() {
    for (final key in _index()) {
      _store.settings.delete(key);
    }
    _store.settings.delete(_indexKey);
  }

  /// How many summaries are kept.
  int get savedCount => _index().length;

  /// The instructions: a short summary in a fixed format the card can
  /// lay out, in the language of the emails.
  static const task =
      'You summarise emails for the person who received them, in a mail '
      'app. Write in the language the emails are written in. Be brief and '
      'factual: only what the emails say, nothing invented, no advice, no '
      'links. Use exactly this format, with these English headings, and '
      'leave out a heading that would have nothing under it:\n'
      '\n'
      'Summary: one or two sentences on what this is about.\n'
      'Key points:\n'
      '- at most five short points\n'
      'Dates:\n'
      '- each date or deadline, and what happens then\n'
      'Amounts:\n'
      '- each amount of money, and what it is for\n'
      'Asked of you:\n'
      '- what the sender asks the reader to do, and by when\n'
      '\n'
      'Use plain text: no Markdown other than the dashes.';

  /// Summarises [message] (or its conversation) with [provider]: the text
  /// so far, as it arrives. Keeps the finished summary. Throws
  /// [AiException] (a refusal is [AiProblem.refused]).
  Stream<String> summarise(
    AiFeatureProvider provider,
    StoredMessage message,
    SummaryScope scope, {
    AiCancel? cancel,
  }) async* {
    final emails = _emails(message, scope);
    final mails = await _promptMails(emails);
    final prompt = MailPrompt();
    final request = prompt.request(
      model: provider.model,
      task: task,
      mails: mails,
      request: emails.length == 1
          ? 'Summarise the email above.'
          : 'Summarise the conversation above (${emails.length} emails, '
                'oldest first).',
      maxOutputTokens: 8000,
      effort: AiEffort.low,
    );
    final text = StringBuffer();
    await for (final event in provider.stream(request, cancel: cancel)) {
      switch (event) {
        case AiTextDelta(text: final piece):
          text.write(piece);
          yield text.toString();
        case AiCompleted(:final response):
          if (response.stopReason == AiStopReason.refusal) {
            throw const AiException(AiProblem.refused, 'declined');
          }
          final summary = SavedSummary(
            text: response.text.trim(),
            provider: provider.kind,
            recipient: provider.recipient,
            model: response.model,
            at: DateTime.now(),
            emails: emails.length,
          );
          _keep(_key(scope, emails), summary);
          yield summary.text;
          return;
      }
    }
    throw const AiException(AiProblem.badResponse, 'the answer ended early');
  }

  /// The emails as [MailPrompt] takes them: headers from the store, text
  /// from the body (downloaded from the user's server if needed), file
  /// names only.
  Future<List<PromptMail>> _promptMails(List<StoredMessage> emails) async {
    final raws = <Uint8List>[];
    final kept = <StoredMessage>[];
    for (final m in emails) {
      var raw = _store.messages.body(m.id);
      if (raw == null) {
        try {
          await loadBody(m.id);
        } on Object {
          // Left out below.
        }
        raw = _store.messages.body(m.id);
      }
      if (raw == null) continue;
      raws.add(raw);
      kept.add(m);
    }
    if (kept.isEmpty) {
      throw const AiException(
        AiProblem.notConfigured,
        'The email isn\'t on this device yet. Try again when you are online.',
      );
    }
    final texts = await compute(_texts, raws);
    return [
      for (final (i, m) in kept.indexed)
        PromptMail(
          from: _who(m.from),
          to: [
            for (final a in _store.messages.addresses(m.id, 'to')) _who(a),
            for (final a in _store.messages.addresses(m.id, 'cc')) _who(a),
          ],
          date: m.sentAt ?? m.receivedAt,
          subject: m.subject,
          body: texts[i].body,
          attachmentNames: texts[i].files,
        ),
    ];
  }

  static String _who(MailAddress? a) => switch (a) {
    null => '(unknown sender)',
    MailAddress(:final displayName?) when displayName.trim().isNotEmpty =>
      '$displayName <${a.address}>',
    _ => a.address,
  };

  static List<({String body, List<String> files})> _texts(
    List<Uint8List> raws,
  ) => [
    for (final raw in raws)
      () {
        final view = MessageView.parse(raw);
        final plain = view.message.textBody?.decodeText().text;
        return (
          body: plain ?? view.body.plainText,
          files: [for (final a in view.attachments) a.displayName],
        );
      }(),
  ];
}
