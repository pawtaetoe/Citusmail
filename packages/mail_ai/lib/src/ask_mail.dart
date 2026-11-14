// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:math';

import 'ai_errors.dart';
import 'ai_types.dart';
import 'mail_prompt.dart';

/// One email offered to the model for an answer, under the number the
/// answer cites it by: its block's number in the prompt, from 1.
final class AskSource {
  const AskSource({required this.id, required this.mail});

  /// The app's own id of the message (never sent).
  final int id;

  /// What is sent: sender, date, subject and an excerpt of the text.
  final PromptMail mail;
}

/// An earlier question in the same conversation, and its answer.
final class AskExchange {
  const AskExchange(this.question, this.answer);

  final String question;

  /// As shown (without citation numbers when it is sent again).
  final String answer;
}

/// A checked answer: what the model said, and which of the emails sent
/// it used.
final class AskAnswer {
  const AskAnswer({
    required this.found,
    required this.text,
    this.cited = const [],
  });

  /// False when the emails did not contain the answer.
  final bool found;

  /// Plain text; citation numbers that name no email sent are taken out.
  final String text;

  /// The numbers (from 1) of the emails sent that the answer used, each
  /// once, in the order it names them. Only numbers of emails that were
  /// sent.
  final List<int> cited;
}

/// Where the matches for a question come from, and how many of the best
/// are sent ([AskMail.pick]): each search that found an email counts
/// once for it, by its weight, and the newest come first among equals.
final class AskMatches {
  final _score = <int, double>{};
  final _at = <int, DateTime>{};
  final _seen = <int, Set<String>>{};

  /// Messages [hits] found by [term], counted [weight] each (once per
  /// term and message).
  void add(String term, Iterable<(int, DateTime)> hits, {double weight = 1}) {
    for (final (id, at) in hits) {
      final seen = _seen.putIfAbsent(id, () => {});
      if (!seen.add(term)) continue;
      _score[id] = (_score[id] ?? 0) + weight;
      _at[id] = at;
    }
  }

  bool get isEmpty => _score.isEmpty;

  /// The searches (terms) that found [id].
  Set<String> foundBy(int id) => {...?_seen[id]};

  /// The [limit] best, best first.
  List<int> best(int limit) {
    final ids = _score.keys.toList()
      ..sort((a, b) {
        final byScore = _score[b]!.compareTo(_score[a]!);
        if (byScore != 0) return byScore;
        final byDate = _at[b]!.compareTo(_at[a]!);
        return byDate != 0 ? byDate : b.compareTo(a);
      });
    return ids.take(max(0, limit)).toList();
  }
}

/// "Ask your mail": a question answered from the user's own mail.
///
/// The search runs on the device; only the few best matches go to the
/// model, through [MailPrompt], as excerpts. The model may first be
/// asked for search words ([queriesRequest]), which sends the question
/// alone, no mail. Everything the model says back is checked
/// ([parseQueries], [parseAnswer]) before it is used: an answer can only
/// cite emails that were sent, and it never leads to an action.
abstract final class AskMail {
  /// Emails sent with a question, unless the caller asks for others.
  static const defaultSources = 8;

  /// Never more than this.
  static const maxSources = 15;

  /// The most of one email's text sent.
  static const excerptChars = 1500;

  /// Search words the model may suggest.
  static const maxQueries = 3;

  /// The longest answer shown.
  static const maxAnswerChars = 3000;

  static final _questionStart = RegExp(
    r'^(who|whom|whose|what|when|where|which|why|how|did|do|does|is|are|'
    r'was|were|can|could|should|will|would|has|have|had|am|any|tell me|'
    r'find|show me|list)\b',
    caseSensitive: false,
  );

  /// Whether [text], typed in search, reads as a question (ends with a
  /// question mark, or starts like one and has a few words) rather than
  /// words to find.
  static bool looksLikeQuestion(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    final words = t.split(RegExp(r'\s+')).length;
    if (t.endsWith('?') || t.endsWith('？')) return words >= 2;
    return words >= 3 && _questionStart.hasMatch(t);
  }

  static final _word = RegExp(
    r"[\p{L}\p{N}][\p{L}\p{N}'’._@-]*",
    unicode: true,
  );

  /// Words that say nothing about which email is meant.
  static final _stopWords = {
    ...('a about after again all am an and any are as at be been before '
            'being but by can could did do does doing email emails find for '
            'from get got had has have he her here him his how i if in into '
            'is it its just last list mail mails me message messages my next '
            'no not of on or our out please say said says she should show so '
            'some tell than that the their them then there these they this '
            'those to up us was we were what whats when where which who whom '
            'whose why will with would you your im')
        .split(' '),
    "what's",
    'what’s',
    "i'm",
    'i’m',
  };

  /// The words of [text] worth searching for, each once, at most [limit]:
  /// small words and question words left out, a plural's "s" and a
  /// possessive's "'s" taken off (a search for "parcel" finds "parcels"
  /// too).
  static List<String> keywords(String text, {int limit = 8}) {
    final out = <String>[];
    for (final m in _word.allMatches(text.toLowerCase())) {
      var w = m[0]!.replaceAll(RegExp(r'[._@-]+$'), '');
      w = w.replaceAll(RegExp(r"['’]s$"), '');
      if (w.length < 2 || _stopWords.contains(w)) continue;
      if (w.length > 4 &&
          w.endsWith('s') &&
          !w.endsWith('ss') &&
          !w.endsWith('us') &&
          !w.endsWith('is')) {
        w = w.substring(0, w.length - 1);
      }
      if (!out.contains(w)) out.add(w);
      if (out.length == limit) break;
    }
    return out;
  }

  /// Asks the model for up to [maxQueries] short searches for
  /// [question] ([earlier] questions of the conversation give context).
  /// Sends no mail: only what the user typed.
  static AiRequest queriesRequest({
    required String model,
    required String question,
    List<String> earlier = const [],
  }) => AiRequest(
    model: model,
    system:
        'You turn a question about someone\'s own email into short searches '
        'for an email app\'s search box. Each search is 1 to 4 words that '
        'would appear in the email that answers it (a sender, a company, a '
        'place, a kind of email such as "boarding pass" or "invoice"). '
        'All words of a search must be in the email. Give 1 to $maxQueries '
        'searches, the most likely first. Reply with JSON only.',
    messages: [
      AiMessage.user(
        [
          if (earlier.isNotEmpty)
            'Earlier questions, for context:\n${[for (final q in earlier) '- ${_line(q)}'].join('\n')}\n',
          'Question: ${_line(question)}',
        ].join('\n'),
      ),
    ],
    maxOutputTokens: 200,
    effort: AiEffort.low,
    jsonSchema: const AiJsonSchema(
      name: 'mail_searches',
      schema: {
        'type': 'object',
        'properties': {
          'queries': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['queries'],
        'additionalProperties': false,
      },
    ),
  );

  /// The searches in [response], checked: short single lines, each once,
  /// at most [maxQueries]. Throws [AiException] ([AiProblem.badResponse])
  /// when the answer is not the JSON asked for.
  static List<String> parseQueries(AiResponse response) {
    final queries = response.json?['queries'];
    if (queries is! List) {
      throw const AiException(AiProblem.badResponse, 'no searches');
    }
    final out = <String>[];
    for (final q in queries) {
      if (q is! String) continue;
      final query = MailPrompt.neutralise(q)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (query.isEmpty || query.length > 60) continue;
      if (query.split(' ').length > 6) continue;
      if (out.any((o) => o.toLowerCase() == query.toLowerCase())) continue;
      out.add(query);
      if (out.length == maxQueries) break;
    }
    return out;
  }

  /// At most [chars] characters of [text], whitespace tidied: the start,
  /// then the passages around the first places [terms] appear, with "…"
  /// where text is left out.
  static String excerpt(
    String text,
    List<String> terms, {
    int chars = excerptChars,
  }) {
    final tidy = text
        .replaceAll(RegExp(r'[ \t ]+'), ' ')
        .replaceAll(RegExp(r'\s*\n\s*(\n\s*)+'), '\n\n')
        .trim();
    if (tidy.length <= chars) return tidy;
    final lower = tidy.toLowerCase();
    final head = min(400, chars ~/ 3);
    final hits = <int>[];
    for (final term in terms) {
      final at = lower.indexOf(term.toLowerCase(), head);
      if (at >= 0) hits.add(at);
    }
    hits.sort();
    if (hits.isEmpty) return '${tidy.substring(0, chars).trimRight()} …';
    final room = (chars - head) ~/ min(hits.length, 3);
    final spans = <(int, int)>[(0, head)];
    for (final at in hits.take(3)) {
      final start = max(0, at - room ~/ 3);
      final end = min(tidy.length, start + room);
      final (lastStart, lastEnd) = spans.last;
      if (start <= lastEnd) {
        spans.last = (lastStart, max(lastEnd, end));
      } else {
        spans.add((start, end));
      }
    }
    final out = StringBuffer();
    for (final (i, (start, end)) in spans.indexed) {
      if (i > 0) out.write(' … ');
      out.write(tidy.substring(start, end).trim());
    }
    if (spans.last.$2 < tidy.length) out.write(' …');
    return out.toString();
  }

  static const _task =
      'You answer the user\'s question about their own email. You get only '
      'the few emails that a search on their device found for it, not the '
      'whole mailbox, and only part of each. Use only what these emails '
      'say: never guess, and never use outside knowledge for facts about '
      'the user. Answer in one to four short sentences, in the language '
      'of the question. After each fact, give the number of the email it '
      'comes from in square brackets, like [2]: the number in that '
      'email\'s start marker. If the emails don\'t contain the answer, set '
      'found to false and say in one sentence that you couldn\'t find it. '
      'Plain text only: no links, no markdown. You only read: you can\'t '
      'do anything for the user, so never offer to. Reply with JSON: '
      'found (true or false), answer (the text), emails (the numbers of '
      'the emails you used).';

  static const answerSchema = AiJsonSchema(
    name: 'mail_answer',
    schema: {
      'type': 'object',
      'properties': {
        'found': {'type': 'boolean'},
        'answer': {'type': 'string'},
        'emails': {
          'type': 'array',
          'items': {'type': 'integer'},
        },
      },
      'required': ['found', 'answer', 'emails'],
      'additionalProperties': false,
    },
  );

  /// The question with [sources] (numbered from 1 in that order) as data
  /// blocks, after the [earlier] questions and answers of the
  /// conversation (their text only: no mail is sent again with them).
  static AiRequest answerRequest({
    required String model,
    required String question,
    required List<AskSource> sources,
    List<AskExchange> earlier = const [],
    MailPrompt? prompt,
  }) {
    final p = prompt ?? MailPrompt();
    return AiRequest(
      model: model,
      system: p.system(_task),
      messages: [
        for (final e in earlier) ...[
          AiMessage.user('Question: ${_line(e.question)}'),
          AiMessage.assistant(withoutCitations(e.answer)),
        ],
        p.userMessage([
          for (final s in sources) s.mail,
        ], 'Question: ${_line(question)}'),
      ],
      maxOutputTokens: 1024,
      jsonSchema: answerSchema,
    );
  }

  static final _citation = RegExp(r'\s?\[(\d{1,3})\]');

  /// [text] without its "[2]" citations (an earlier answer, whose numbers
  /// meant that question's emails).
  static String withoutCitations(String text) =>
      text.replaceAll(_citation, '').trim();

  /// The answer in [response] to a question sent with [sent] emails,
  /// checked: citations of numbers outside 1..[sent] are dropped (from
  /// the list and from the text), and the text is cut to
  /// [maxAnswerChars]. Throws [AiException]: [AiProblem.refused] when the
  /// model declined, [AiProblem.badResponse] when the answer is not the
  /// JSON asked for.
  static AskAnswer parseAnswer(AiResponse response, {required int sent}) {
    if (response.stopReason == AiStopReason.refusal) {
      throw const AiException(AiProblem.refused, 'declined');
    }
    final json = response.json;
    final found = json?['found'];
    final answer = json?['answer'];
    final emails = json?['emails'];
    if (found is! bool || answer is! String || emails is! List) {
      throw const AiException(AiProblem.badResponse, 'not the JSON asked for');
    }
    bool valid(int n) => n >= 1 && n <= sent;
    var text = answer.replaceAllMapped(
      _citation,
      (m) => valid(int.parse(m[1]!)) ? m[0]! : '',
    );
    text = MailPrompt.neutralise(text).trim();
    if (text.length > maxAnswerChars) {
      text = '${text.substring(0, maxAnswerChars).trimRight()}…';
    }
    if (!found) {
      return AskAnswer(
        found: false,
        text: text.isEmpty ? 'I couldn\'t find that in your mail.' : text,
      );
    }
    if (text.isEmpty) {
      throw const AiException(AiProblem.badResponse, 'an empty answer');
    }
    final cited = <int>[];
    void cite(int n) {
      if (valid(n) && !cited.contains(n)) cited.add(n);
    }

    for (final m in _citation.allMatches(text)) {
      cite(int.parse(m[1]!));
    }
    for (final e in emails) {
      if (e is num && e == e.roundToDouble()) cite(e.toInt());
    }
    return AskAnswer(found: true, text: text, cited: cited);
  }

  /// One line, neutralised.
  static String _line(String text) =>
      MailPrompt.neutralise(text).replaceAll(RegExp(r'\s+'), ' ').trim();
}
