// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import '../services/ai_assistant.dart';
import '../services/app_services.dart';
import 'appointments_model.dart';
import 'deliveries_model.dart';
import 'message_reads.dart';
import 'subscriptions_model.dart';
import 'trips_model.dart';

/// Messages behind the "Found in your mail" items (trips, deliveries,
/// subscriptions, appointments) that [question] is about, newest first.
typedef AskHints = Future<List<int>> Function(
  MailStore store,
  String question,
  DateTime now,
);

enum AskPhase {
  /// Looking for matches on the device.
  searching,

  /// Waiting for the provider.
  asking,

  /// Done: an answer, "not found", or nothing matched (nothing sent).
  answered,

  /// Stopped, or the provider gave no answer ([AskTurn.error]).
  failed,
}

/// One question in the panel, and what became of it.
final class AskTurn {
  AskTurn(this.question, this.recipient);

  final String question;

  /// Who the question and its emails went to ("Anthropic").
  final String recipient;

  AskPhase phase = AskPhase.searching;

  /// The emails sent with the question, in the order they were numbered
  /// (from 1).
  List<StoredMessage> sent = const [];

  /// The checked answer, once there is one.
  AskAnswer? answer;

  /// Why there is no answer, for the user.
  String? error;

  /// Nothing on the device matched, so nothing was sent.
  bool get nothingMatched =>
      phase == AskPhase.answered && answer == null && sent.isEmpty;

  /// The emails the answer used, each with its number in the answer.
  List<(int, StoredMessage)> get cited => [
    for (final n in answer?.cited ?? const <int>[])
      if (n >= 1 && n <= sent.length) (n, sent[n - 1]),
  ];
}

/// "Ask your mail": answers questions typed in search from the user's own
/// mail, with their own key.
///
/// Matches are found on the device (the app's search, and the "Found in
/// your mail" items the question is about); only the best few
/// ([sources]) are sent, as excerpts, through [AskMail] and
/// [MailPrompt]. The model may first suggest searches, which sends the
/// question alone. A follow-up sends the earlier questions and answers
/// as text, with the emails that match it. Answers only read: nothing
/// in them is acted on, and they can only point to emails that were
/// sent.
final class AskMailModel extends ChangeNotifier {
  AskMailModel(
    this._services, {
    int sources = AskMail.defaultSources,
    AskHints? hints,
    DateTime Function()? now,
  }) : sources = sources.clamp(1, AskMail.maxSources),
       _hints = hints ?? foundInMailHints,
       _now = now ?? DateTime.now;

  final AppServices _services;
  final AskHints _hints;
  final DateTime Function() _now;

  /// Emails sent with a question at most.
  final int sources;

  /// Searches per word or suggested search.
  static const perSearch = 30;

  MailStore get _store => _services.store;

  /// Every question asked in this panel, oldest first.
  final turns = <AskTurn>[];

  AiCancel? _cancel;
  bool _disposed = false;

  bool get busy => switch (turns.lastOrNull?.phase) {
    AskPhase.searching || AskPhase.asking => true,
    _ => false,
  };

  /// Asks [question]. [confirm] is asked first if the user has not yet
  /// agreed that this feature sends mail to the provider (once per
  /// provider); without it, nothing happens.
  Future<void> ask(
    String question, {
    required Future<bool> Function(String recipient) confirm,
  }) async {
    final q = question.trim();
    if (q.isEmpty || busy) return;
    final provider = await _services.ai.providerFor(AiFeatures.ask.id);
    if (provider == null || _disposed) return;
    if (provider.needsConfirmation) {
      if (!await confirm(provider.recipient) || _disposed) return;
      provider.confirm();
    }
    final earlier = [...turns];
    final turn = AskTurn(q, provider.recipient);
    turns.add(turn);
    _notify();
    final cancel = _cancel = AiCancel();
    try {
      final questions = [for (final t in earlier.reversed.take(3)) t.question];
      final queries = await _queries(provider, q, questions, cancel);
      final hinted = await _hintsFor(q);
      if (cancel.isCancelled) throw aiCancelled;
      final ids = _search(q, questions.firstOrNull, queries, hinted);
      final messages = [for (final id in ids) ?_store.messages.byId(id)];
      if (messages.isEmpty) {
        turn.phase = AskPhase.answered;
        return;
      }
      final texts = await plainTextReads.read(_store, messages);
      final terms = {
        ...AskMail.keywords(q),
        for (final query in queries) ...AskMail.keywords(query),
      }.toList();
      final sent = [
        for (final (i, m) in messages.indexed)
          AskSource(
            id: m.id,
            mail: PromptMail(
              from: _sender(m.from),
              date: m.receivedAt,
              subject: m.subject,
              body: AskMail.excerpt(texts[i], terms),
            ),
          ),
      ];
      if (cancel.isCancelled) throw aiCancelled;
      turn
        ..sent = messages
        ..phase = AskPhase.asking;
      _notify();
      final exchanges = [
        for (final t in earlier)
          if (t.answer case final a?) AskExchange(t.question, a.text),
      ];
      final key = [
        provider.kind.id,
        provider.model,
        q,
        for (final e in exchanges) ...[e.question, e.answer],
        for (final s in sent) ...['${s.id}', s.mail.subject ?? '', s.mail.body],
      ].join('\u0000');
      final cache = _cacheOf(_store);
      final answer =
          cache.answers.take(key) ??
          AskMail.parseAnswer(
            await provider.complete(
              AskMail.answerRequest(
                model: provider.model,
                question: q,
                sources: sent,
                earlier: exchanges,
              ),
              cancel: cancel,
            ),
            sent: sent.length,
          );
      cache.answers.put(key, answer);
      turn
        ..answer = answer
        ..phase = AskPhase.answered;
    } on AiException catch (e) {
      turn
        ..error = e.explain(provider.recipient)
        ..phase = AskPhase.failed;
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      _notify();
    }
  }

  /// Searches the model suggests for [question] (only the question is
  /// sent), remembered per question; none when its answer can't be read.
  Future<List<String>> _queries(
    AiFeatureProvider provider,
    String question,
    List<String> earlier,
    AiCancel cancel,
  ) async {
    final cache = _cacheOf(_store);
    final key = [
      provider.kind.id,
      provider.model,
      question,
      ...earlier,
    ].join('\u0000');
    if (cache.queries.take(key) case final known?) return known;
    try {
      final queries = AskMail.parseQueries(
        await provider.complete(
          AskMail.queriesRequest(
            model: provider.model,
            question: question,
            earlier: earlier,
          ),
          cancel: cancel,
        ),
      );
      cache.queries.put(key, queries);
      return queries;
    } on AiException catch (e) {
      // Searching for the question's own words still works.
      if (e.problem == AiProblem.badResponse) return const [];
      rethrow;
    }
  }

  /// The best matches on the device: emails found by the model's
  /// [queries] count double, then each word of the question, then the
  /// [previous] question's words (for a follow-up such as "and which
  /// terminal?") and the [hinted] "Found in your mail" emails.
  List<int> _search(
    String question,
    String? previous,
    List<String> queries,
    List<int> hinted,
  ) {
    final boxes = <int, bool>{};
    bool searchable(StoredMessage m) => boxes.putIfAbsent(m.mailboxId, () {
      final box = _store.mailboxes.byId(m.mailboxId);
      return box != null &&
          !box.isAppData &&
          box.specialUse != SpecialUse.junk &&
          box.specialUse != SpecialUse.trash;
    });
    Iterable<(int, DateTime)> hits(Iterable<StoredMessage> found) => [
      for (final m in found)
        if (searchable(m)) (m.id, m.receivedAt),
    ];
    Iterable<(int, DateTime)> find(String text) =>
        hits(_store.messages.search(text, limit: perSearch));

    final matches = AskMatches();
    for (final query in queries) {
      matches.add('?$query', find(query), weight: 2);
    }
    final words = {
      ...AskMail.keywords(question),
      for (final query in queries) ...AskMail.keywords(query),
    };
    for (final word in words) {
      matches.add(word, find(word));
    }
    if (previous != null) {
      for (final word in AskMail.keywords(previous)) {
        if (!words.contains(word)) matches.add(word, find(word), weight: 0.5);
      }
    }
    matches.add(_found, [
      for (final id in hinted)
        if (_store.messages.byId(id) case final m? when searchable(m))
          (m.id, m.receivedAt),
    ], weight: 0.5);
    // A "Found in your mail" email that no search found joins only a
    // few at a time: the question's words matter more than its topic.
    var foundOnly = 0;
    return [
      for (final id in matches.best(sources * 3))
        if (matches.foundBy(id).length > 1 ||
            !matches.foundBy(id).contains(_found) ||
            foundOnly++ < maxFoundOnly)
          id,
    ].take(sources).toList();
  }

  static const _found = '(found in your mail)';

  /// "Found in your mail" emails sent that no search found, at most.
  static const maxFoundOnly = 3;

  /// The "Found in your mail" emails [question] is about; none if they
  /// can't be read now (they only help).
  Future<List<int>> _hintsFor(String question) async {
    try {
      return await _hints(_store, question, _now());
    } on Exception {
      return const [];
    }
  }

  /// Stops the question under way.
  void stop() => _cancel?.cancel();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }

  static String _sender(MailAddress? from) => switch (from) {
    null => '(unknown sender)',
    MailAddress(:final displayName?) when displayName.trim().isNotEmpty =>
      '$displayName <${from.address}>',
    _ => from.address,
  };

  static final _caches = Expando<_AskCache>();

  static _AskCache _cacheOf(MailStore store) => _caches[store] ??= _AskCache();
}

/// Answers and suggested searches already paid for, in memory, per
/// store: asking the same again (going back to the same search, say)
/// costs nothing.
final class _AskCache {
  final answers = _Recent<AskAnswer>();
  final queries = _Recent<List<String>>();
}

/// At most [size] entries, the least recently used dropped first.
final class _Recent<T> {
  static const size = 50;

  final _entries = <String, T>{};

  T? take(String key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(String key, T value) {
    _entries
      ..remove(key)
      ..[key] = value;
    while (_entries.length > size) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// Words that make a question about one kind of "Found in your mail"
/// item.
final _tripWords =
    ('flight fly flying plane airport terminal gate boarding depart '
            'departure land arrival hotel stay staying check-in checkin '
            'trip travel train bus ferry car rental booking reservation')
        .split(' ')
        .toSet();
final _deliveryWords =
    ('parcel package delivery deliver delivered arrive arriving '
            'shipped shipping shipment tracking courier order ordered')
        .split(' ')
        .toSet();
final _subscriptionWords =
    ('subscription subscribed subscribe renew renewal plan '
            'membership trial paying pay charged charge bill billed cancel')
        .split(' ')
        .toSet();
final _appointmentWords =
    ('appointment dentist doctor gp clinic haircut table restaurant '
            'dinner lunch consultation visit reservation booking')
        .split(' ')
        .toSet();

/// The emails of the trips, deliveries, subscriptions and appointments
/// found in [store] that [question] is about by its words (those the
/// user hid aside), at most five of each kind, the newest first. Reads
/// mail the way those pages do, off the UI thread.
Future<List<int>> foundInMailHints(
  MailStore store,
  String question,
  DateTime now,
) async {
  final words = AskMail.keywords(question, limit: 20).toSet();
  bool about(Set<String> topic) => words.any(topic.contains);
  final out = <int>[];
  void newest(Iterable<int> ids) {
    final messages = [for (final id in ids.toSet()) ?store.messages.byId(id)]
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    out.addAll(messages.take(5).map((m) => m.id));
  }

  if (about(_tripWords)) {
    final found = await findTrips(store, now);
    final left = {...found.hidden, ...found.learned};
    newest([
      for (final b in found.all)
        if (!left.contains(b.key))
          for (final r in b.records) r.email.messageId,
    ]);
  }
  if (about(_deliveryWords)) {
    final found = await findDeliveries(store, now);
    final left = {...found.hidden, ...found.learned};
    newest([
      for (final d in found.all)
        if (!left.contains(d.key))
          for (final r in d.records) r.email.messageId,
    ]);
  }
  if (about(_subscriptionWords)) {
    final found = await findSubscriptions(store, now, monthlyRenewals: false);
    final left = {...found.hidden, ...found.learned};
    newest([
      for (final s in found.all)
        if (!left.contains(s.company))
          for (final r in s.records) r.email.messageId,
    ]);
  }
  if (about(_appointmentWords)) {
    final found = await findAppointments(store, now);
    final left = {...found.hidden, ...found.learned};
    newest([
      for (final a in found.all)
        if (!left.contains(a.key))
          for (final r in a.records) r.email.messageId,
    ]);
  }
  return out;
}
