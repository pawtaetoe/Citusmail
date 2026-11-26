// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';

/// What the user asked "Write with AI" for.
sealed class WritingTask {
  const WritingTask();

  /// What it is called in the sheet ("Draft a reply", "Shorter").
  String get label;
}

/// A reply drafted from the email being answered (for a forward: the
/// note that goes above it), with the user's optional instruction.
final class DraftReplyTask extends WritingTask {
  const DraftReplyTask({
    required this.source,
    this.note = '',
    this.forward = false,
  });

  /// The email being answered or forwarded: the only email sent.
  final PromptMail source;

  /// "Say yes but ask to move it to Friday" (may be empty).
  final String note;

  final bool forward;

  @override
  String get label => forward ? 'Note for the forward' : 'Draft a reply';
}

/// How [RewriteTask] changes the text.
enum RewriteStyle {
  shorter('Shorter'),
  friendlier('Friendlier'),
  formal('More formal'),
  fix('Fix spelling & grammar'),
  translate('Translate to…'),
  custom('Your instruction');

  const RewriteStyle(this.label);

  final String label;
}

/// The user's own text, rewritten.
final class RewriteTask extends WritingTask {
  const RewriteTask({
    required this.body,
    required this.style,
    this.language,
    this.instruction = '',
  });

  /// What the user wrote: the body only, never the sign-off or quote.
  final String body;
  final RewriteStyle style;

  /// For [RewriteStyle.translate].
  final String? language;

  /// For [RewriteStyle.custom].
  final String instruction;

  @override
  String get label => switch (style) {
    RewriteStyle.translate => 'Translated to $language',
    RewriteStyle.custom => 'Rewritten: $instruction',
    _ => style.label,
  };
}

/// The prompts of "Write with AI", and what is done with the answer.
///
/// The model only ever writes text for the body. What it writes is shown
/// to the user, who chooses whether to use it; nothing in it can change
/// the recipients, subject, attachments, sign-off or quote, or send
/// anything, because the app only ever puts it into the body.
abstract final class WritingHelp {
  /// The languages "Translate to…" offers, in their own words where
  /// the model understands both.
  static const languages = [
    'English',
    'Spanish',
    'French',
    'German',
    'Italian',
    'Portuguese',
    'Dutch',
    'Swedish',
    'Danish',
    'Norwegian',
    'Finnish',
    'Polish',
    'Czech',
    'Greek',
    'Turkish',
    'Ukrainian',
    'Russian',
    'Arabic',
    'Hebrew',
    'Hindi',
    'Indonesian',
    'Vietnamese',
    'Thai',
    'Chinese (Simplified)',
    'Chinese (Traditional)',
    'Japanese',
    'Korean',
  ];

  /// The most the model may write (a long email, not a book).
  static const maxOutputTokens = 2048;

  /// The rules every request follows.
  static String _rules(String? userName) {
    final name = userName?.trim() ?? '';
    const rules =
        'You help someone write an email in their mail app. You only write '
        'text: the app shows it to them, and they decide whether to use '
        'it. You cannot send the email, address it, or change anything but '
        'its text.\n'
        '\n'
        'Rules:\n'
        '- Answer with the text of the email body only, as plain text: no '
        'subject line, no To, Cc or Bcc lines, no Markdown, and no comments '
        'about what you did.\n'
        '- Do not end with a sign-off or signature with a name (like "Best '
        'regards, Sam"): the app adds the user\'s own sign-off below your '
        'text. A greeting at the start is fine.\n'
        '- Never invent facts. Do not add dates, times, prices, amounts, '
        'names, email addresses, phone numbers, links or promises that are '
        'not in the email or in the user\'s words. Where one is needed and '
        'you don\'t know it, write a placeholder in square brackets, like '
        '[time].';
    if (name.isEmpty) return rules;
    final safe = MailPrompt.neutralise(name).replaceAll(RegExp(r'\s+'), ' ');
    return '$rules\n- The user\'s name is "$safe". Never change it or use '
        'another name for them.';
  }

  static String _rewriteHow(RewriteTask task) => switch (task.style) {
    RewriteStyle.shorter =>
      'Make it shorter and clearer: keep everything that matters, drop '
          'repetition and filler.',
    RewriteStyle.friendlier =>
      'Make it warmer and friendlier, still natural and not over the top.',
    RewriteStyle.formal =>
      'Make it more formal and polite, as for work or someone the user '
          'doesn\'t know well.',
    RewriteStyle.fix =>
      'Only correct spelling, grammar and punctuation. Change nothing else: '
          'keep the wording, the tone and the line breaks.',
    RewriteStyle.translate =>
      'Translate it into ${task.language ?? 'English'}. Keep the meaning, '
          'the tone and the line breaks.',
    RewriteStyle.custom => 'Change it as the user asks below.',
  };

  /// The request for [task], with [model]. [prompt] makes the email
  /// blocks (its nonce marks them); [userName] is the user's display
  /// name.
  static AiRequest request(
    WritingTask task, {
    required String model,
    String? userName,
    MailPrompt? prompt,
  }) {
    final p = prompt ?? MailPrompt();
    final rules = _rules(userName);
    switch (task) {
      case DraftReplyTask(:final source, :final note, :final forward):
        final what = forward
            ? 'The user is forwarding the email below (email 1). Write the '
                  'short note that goes above it, to the people they forward '
                  'it to.'
            : 'Write the user\'s reply to the email below (email 1). Make it '
                  'as short as the email calls for, and answer what it '
                  'asks.';
        final ask = note.trim().isEmpty
            ? (forward ? 'Write the note.' : 'Write the reply.')
            : 'What the user wants to say: '
                  '"${MailPrompt.neutralise(note.trim())}"';
        return p.request(
          model: model,
          task:
              '$rules\n\n$what Write in the same language as email 1, '
              'unless the user asks for another. Do not quote email 1: the '
              'app keeps the quote below the reply.',
          mails: [source],
          request: ask,
          maxOutputTokens: maxOutputTokens,
          effort: AiEffort.low,
        );
      case RewriteTask(:final body, :final style, :final instruction):
        final keepLanguage = style == RewriteStyle.translate
            ? ''
            : ' Keep the language it is written in.';
        final ask = style == RewriteStyle.custom
            ? 'Rewrite email 1 as the user asks: '
                  '"${MailPrompt.neutralise(instruction.trim())}"'
            : 'Rewrite email 1.';
        return p.request(
          model: model,
          task:
              '$rules\n\nRewrite the user\'s own draft (email 1). '
              '${_rewriteHow(task)} Keep its meaning, its facts and anything '
              'it asks or promises, with names, dates, amounts and links '
              'exactly as they are.$keepLanguage',
          mails: [
            PromptMail(
              from: userName?.trim().isNotEmpty == true
                  ? '${userName!.trim()} (the user)'
                  : 'The user',
              subject: 'The user\'s draft',
              body: body,
            ),
          ],
          request: ask,
          maxOutputTokens: maxOutputTokens,
          effort: AiEffort.low,
        );
    }
  }

  /// Says what goes to [recipient] for [task], for the sheet.
  static String sentNote(WritingTask task, String recipient) => switch (task) {
    DraftReplyTask(forward: true) =>
      'Sent to $recipient: the email you are forwarding, your name and your '
          'instruction.',
    DraftReplyTask() =>
      'Sent to $recipient: the email you are answering, your name and your '
          'instruction.',
    RewriteTask() =>
      'Sent to $recipient: the text you wrote and your name (not the '
          'recipients, sign-off or quote).',
  };

  /// What identifies [task] with [model], so the same request asked
  /// again is answered from what is kept (costing nothing).
  static String cacheKey(WritingTask task, String model) => switch (task) {
    DraftReplyTask(:final source, :final note, :final forward) => [
      'reply',
      model,
      '$forward',
      note.trim(),
      source.from,
      source.subject ?? '',
      source.body,
    ].join('\u0000'),
    RewriteTask(
      :final body,
      :final style,
      :final language,
      :final instruction,
    ) =>
      [
        'rewrite',
        model,
        style.name,
        language ?? '',
        instruction.trim(),
        body,
      ].join('\u0000'),
  };

  /// The model's [text], made fit for the body: no fences around it, no
  /// subject or address lines at the top, no echoed email markers
  /// ([nonce]), and no sign-off ([signOff]) at the end that the app adds
  /// anyway. May be empty.
  static String clean(String text, {String? nonce, String? signOff}) {
    var out = text.replaceAll('\r\n', '\n').trim();
    // ```text ... ``` around the whole answer.
    final fenced = RegExp(r'^```[^\n]*\n([\s\S]*?)\n?```$').firstMatch(out);
    if (fenced != null) out = fenced[1]!.trim();
    var lines = out.split('\n');
    if (nonce != null && nonce.isNotEmpty) {
      lines = [
        for (final line in lines)
          if (!line.contains(nonce)) line,
      ];
    }
    // "Subject: …" or "To: …" lines before the text: never used as such.
    final header = RegExp(
      r'^(subject|to|cc|bcc|from)\s*:',
      caseSensitive: false,
    );
    while (lines.isNotEmpty &&
        (header.hasMatch(lines.first.trim()) || lines.first.trim().isEmpty)) {
      lines = lines.sublist(1);
    }
    out = lines.join('\n').trim();
    final ending = signOff?.trim() ?? '';
    if (ending.isNotEmpty && out.endsWith(ending)) {
      out = out.substring(0, out.length - ending.length).trimRight();
    }
    return out;
  }

  /// A reply's quote as the email's own text: without the "On …, … wrote:"
  /// line and one level of `>`.
  static String unquote(String quote) {
    final lines = quote.replaceAll('\r\n', '\n').split('\n');
    if (lines.isNotEmpty && RegExp(r'^On .+ wrote:$').hasMatch(lines.first)) {
      lines.removeAt(0);
    }
    return [
      for (final line in lines)
        if (line.startsWith('> '))
          line.substring(2)
        else if (line.startsWith('>'))
          line.substring(1)
        else
          line,
    ].join('\n').trim();
  }

  /// The first line of a forward's quote.
  static const forwardMark = '---------- Forwarded message ----------';

  /// A forward's quote as an email: its From, Subject and text.
  static PromptMail? forwarded(String quote, {List<String> files = const []}) {
    final lines = quote.replaceAll('\r\n', '\n').split('\n');
    if (lines.isEmpty || lines.first.trim() != forwardMark) return null;
    String? from;
    String? subject;
    var i = 1;
    for (; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) break;
      if (line.startsWith('From: ')) from = line.substring(6).trim();
      if (line.startsWith('Subject: ')) subject = line.substring(9).trim();
    }
    final body = lines.skip(i).join('\n').trim();
    if (body.isEmpty) return null;
    return PromptMail(
      from: from ?? 'Unknown sender',
      subject: subject,
      body: body,
      attachmentNames: files,
    );
  }
}

/// Where one request of "Write with AI" stands.
enum WritingState { running, done, stopped, failed }

/// One request of "Write with AI": the text as it streams in, then the
/// cleaned answer, or why there is none.
final class WritingRun extends ChangeNotifier {
  WritingRun({
    required this.task,
    required this.request,
    required this.recipient,
    required this.stream,
    this.nonce,
    this.signOff,
    this.cached,
    this.onDone,
  });

  final WritingTask task;
  final AiRequest request;

  /// Who answers ("Anthropic").
  final String recipient;

  /// The feature's provider (which checks the monthly limit).
  final Stream<AiEvent> Function(AiRequest, {AiCancel? cancel}) stream;
  final String? nonce;
  final String? signOff;

  /// The answer kept from the same request before: no new request.
  final String? cached;

  /// Called with the cleaned answer when it is complete.
  final void Function(String text)? onDone;

  WritingState state = WritingState.running;

  /// What has been written so far, or the whole cleaned answer.
  String text = '';

  /// Why it failed, for the user.
  String? error;

  /// The answer reached its length limit and may be cut off.
  bool cutOff = false;

  /// Came from what was kept, not a new request.
  bool get fromCache => cached != null;

  final _cancel = AiCancel();
  StreamSubscription<AiEvent>? _subscription;
  bool _disposed = false;

  void _set(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// Asks (or answers from [cached]).
  void start() {
    if (cached case final kept?) {
      _set(() {
        text = kept;
        state = WritingState.done;
      });
      return;
    }
    final buffer = StringBuffer();
    try {
      _subscription = stream(request, cancel: _cancel).listen(
        (event) {
          switch (event) {
            case AiTextDelta(text: final piece):
              buffer.write(piece);
              _set(() => text = buffer.toString().trimLeft());
            case AiCompleted(:final response):
              _finish(response, buffer.toString());
          }
        },
        onError: (Object e) => _fail(e),
        cancelOnError: true,
      );
    } on Object catch (e) {
      _fail(e);
    }
  }

  void _finish(AiResponse response, String streamed) {
    if (state != WritingState.running) return;
    if (response.stopReason == AiStopReason.refusal) {
      _set(() {
        state = WritingState.failed;
        error = '$recipient declined to write this one.';
      });
      return;
    }
    final raw = response.text.isNotEmpty ? response.text : streamed;
    final cleaned = WritingHelp.clean(raw, nonce: nonce, signOff: signOff);
    if (cleaned.isEmpty) {
      _set(() {
        state = WritingState.failed;
        error = '$recipient sent back no text. Try again.';
      });
      return;
    }
    _set(() {
      text = cleaned;
      cutOff = response.stopReason == AiStopReason.maxTokens;
      state = WritingState.done;
    });
    onDone?.call(cleaned);
  }

  void _fail(Object e) {
    if (state != WritingState.running) return;
    if (e is AiException && e.problem == AiProblem.cancelled) {
      _stopped();
      return;
    }
    _set(() {
      state = WritingState.failed;
      error = e is AiException
          ? e.explain(recipient)
          : 'Something went wrong: $e';
    });
  }

  void _stopped() => _set(() {
    text = WritingHelp.clean(text, nonce: nonce, signOff: signOff);
    state = WritingState.stopped;
  });

  /// Stops writing; what was written so far stays.
  void stop() {
    if (state != WritingState.running) return;
    _cancel.cancel();
    unawaited(_subscription?.cancel());
    _stopped();
  }

  @override
  void dispose() {
    if (state == WritingState.running) {
      _cancel.cancel();
      unawaited(_subscription?.cancel());
    }
    _disposed = true;
    super.dispose();
  }
}

/// "Write with AI" for one compose window: keeps each answer, so asking
/// the same again (after Discard, say) costs nothing; "Try again" asks
/// anew.
final class WritingAssistant {
  final _kept = <String, String>{};

  /// A run of [task] with [model], streaming from [stream] (the feature's
  /// provider, which checks the monthly limit and counts the tokens).
  /// [fresh] asks again even if an answer is kept.
  WritingRun run(
    WritingTask task, {
    required String model,
    required String recipient,
    required Stream<AiEvent> Function(AiRequest, {AiCancel? cancel}) stream,
    String? userName,
    String? signOff,
    bool fresh = false,
  }) {
    final key = WritingHelp.cacheKey(task, model);
    final prompt = MailPrompt();
    return WritingRun(
      task: task,
      request: WritingHelp.request(
        task,
        model: model,
        userName: userName,
        prompt: prompt,
      ),
      recipient: recipient,
      stream: stream,
      nonce: prompt.nonce,
      signOff: signOff,
      cached: fresh ? null : _kept[key],
      onDone: (text) => _kept[key] = text,
    )..start();
  }
}
