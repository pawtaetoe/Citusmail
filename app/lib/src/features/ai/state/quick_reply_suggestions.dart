// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_store/mail_store.dart';

import '../../../services/ai_assistant.dart';
import 'ai_task.dart';

/// The replies suggested for one email: at most [QuickReplies.max],
/// already checked ([QuickReplies.validate]).
final class ReplySuggestions extends AiTask<List<String>> {
  ReplySuggestions._(this.messageId);

  final MessageId messageId;
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

  final _cache = <MessageId, ReplySuggestions>{};

  /// What was suggested for [messageId], or is being.
  ReplySuggestions? find(MessageId messageId) => _cache[messageId];

  /// Asks for replies to [mail] (the email [messageId]), once [confirm]
  /// agrees to send it to the provider (`confirmAiSend`, which asks the
  /// user the first time).
  Future<void> suggest(
    MessageId messageId,
    PromptMail mail, {
    required Future<bool> Function(AiFeatureProvider provider) confirm,
  }) async {
    if (_cache[messageId] case final s? when s.state is! AiFailed) return;
    final provider = await _ai.providerFor(AiFeatures.quickReplies.id);
    final s = ReplySuggestions._(messageId)..addListener(notifyListeners);
    if (provider == null) {
      _put(s).failed(
        'Quick replies aren\'t set up. Turn them on in Settings, AI '
        'assistant.',
      );
      return;
    }
    s.recipient = provider.recipient;
    if (!await confirm(provider)) return;
    _put(s);
    await s.run(
      (run) async => QuickReplies.parse(
        run.refusing(
          await provider.complete(
            QuickReplies.request(model: provider.model, mail: mail),
            cancel: run.cancel,
          ),
        ),
      ),
    );
    if (s.state is AiStopped && identical(_cache[messageId], s)) {
      _cache.remove(messageId);
      notifyListeners();
    }
  }

  /// Stops asking.
  void stop(MessageId messageId) {
    final s = _cache[messageId];
    if (s == null || !s.isRunning) return;
    s.stop();
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
