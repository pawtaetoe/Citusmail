// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';

import '../services/ai_assistant.dart';

enum SuggestionStatus { working, done, failed }

/// The replies suggested for one email.
final class ReplySuggestions {
  ReplySuggestions._(this.messageId);

  final int messageId;
  SuggestionStatus status = SuggestionStatus.working;

  /// Who suggested them ("Anthropic").
  String recipient = '';

  /// At most [QuickReplies.max], already checked ([QuickReplies.validate]).
  List<String> replies = const [];

  /// The problem, in plain words, when it [SuggestionStatus.failed].
  String? problem;

  AiCancel? _cancel;
}

/// "Suggest replies" in the reader: asked for only when the user taps
/// the button (never on opening an email), and kept per email while the
/// app runs so asking again costs nothing.
final class QuickReplySuggestions extends ChangeNotifier {
  QuickReplySuggestions(this._ai);

  final AiAssistant _ai;

  static final _all = Expando<QuickReplySuggestions>();

  /// The suggestions made with [ai] (one set while the app runs).
  static QuickReplySuggestions of(AiAssistant ai) =>
      _all[ai] ??= QuickReplySuggestions(ai);

  /// How many emails' suggestions are kept, the oldest dropped first.
  static const keep = 40;

  final _cache = <int, ReplySuggestions>{};

  /// What was suggested for [messageId], or is being.
  ReplySuggestions? find(int messageId) => _cache[messageId];

  /// Asks for replies to [mail] (the email [messageId]), once [confirm]
  /// agrees to send it to the provider (`confirmAiSend`, which asks the
  /// user the first time).
  Future<void> suggest(
    int messageId,
    PromptMail mail, {
    required Future<bool> Function(AiFeatureProvider provider) confirm,
  }) async {
    if (_cache[messageId] case final s?
        when s.status != SuggestionStatus.failed) {
      return;
    }
    final provider = await _ai.providerFor(AiFeatures.quickReplies.id);
    final s = ReplySuggestions._(messageId);
    if (provider == null) {
      _put(s)
        ..status = SuggestionStatus.failed
        ..problem =
            'Quick replies aren\'t set up. Turn them on in Settings, AI '
            'assistant.';
      notifyListeners();
      return;
    }
    s.recipient = provider.recipient;
    if (!await confirm(provider)) return;
    _put(s);
    final cancel = s._cancel = AiCancel();
    notifyListeners();
    try {
      final response = await provider.complete(
        QuickReplies.request(model: provider.model, mail: mail),
        cancel: cancel,
      );
      if (response.stopReason == AiStopReason.refusal) {
        throw const AiException(AiProblem.refused, 'refused');
      }
      s
        ..replies = QuickReplies.parse(response)
        ..status = SuggestionStatus.done;
    } on AiException catch (e) {
      if (e.problem == AiProblem.cancelled) {
        if (identical(_cache[messageId], s)) _cache.remove(messageId);
      } else {
        s
          ..status = SuggestionStatus.failed
          ..problem = e.explain(s.recipient);
      }
    } finally {
      s._cancel = null;
      notifyListeners();
    }
  }

  /// Stops asking.
  void stop(int messageId) {
    final s = _cache[messageId];
    if (s == null || s.status != SuggestionStatus.working) return;
    s._cancel?.cancel();
    _cache.remove(messageId);
    notifyListeners();
  }

  ReplySuggestions _put(ReplySuggestions s) {
    _cache
      ..remove(s.messageId)
      ..[s.messageId] = s;
    while (_cache.length > keep) {
      _cache.remove(_cache.keys.first);
    }
    return s;
  }
}
