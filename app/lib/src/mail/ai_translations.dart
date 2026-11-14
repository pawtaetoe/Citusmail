// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';

import '../services/ai_assistant.dart';

enum TranslationStatus { working, done, failed }

/// One email's translation into one language, as it streams in.
final class Translation {
  Translation._(this.messageId, this.language);

  final int messageId;

  /// The language it is (being) translated into, as a code (`en`).
  final String language;

  TranslationStatus status = TranslationStatus.working;

  /// Who translated it ("Anthropic").
  String recipient = '';

  /// The problem, in plain words, when it [TranslationStatus.failed].
  String? problem;

  /// It stopped at the model's length limit: the end is missing.
  bool cutOff = false;

  final _text = StringBuffer();

  /// The translation so far, as plain text without hidden characters.
  String get text => MailTranslation.clean(_text.toString());

  AiCancel? _cancel;
}

/// The reader's translations: one per email and language, kept while the
/// app runs (a repeat costs nothing), and which emails show theirs.
///
/// Translating sends only the email asked about, and only when the user
/// asks; the translation is text, shown in place of the original until
/// the user goes back to it.
final class MailTranslations extends ChangeNotifier {
  MailTranslations(this._ai);

  final AiAssistant _ai;

  static final _all = Expando<MailTranslations>();

  /// The translations made with [ai] (one set while the app runs).
  static MailTranslations of(AiAssistant ai) =>
      _all[ai] ??= MailTranslations(ai);

  /// How many translations are kept, the oldest dropped first.
  static const keep = 40;

  final _cache = <(int, String), Translation>{};
  final _shown = <int, String>{};
  final _notNow = <int>{};
  final _guesses = <int, String?>{};

  /// [messageId]'s translation into [language], finished or not.
  Translation? find(int messageId, String language) =>
      _cache[(messageId, LanguageGuess.baseCode(language))];

  /// The translation [messageId] shows instead of its text, if any.
  Translation? shown(int messageId) => switch (_shown[messageId]) {
    final language? => find(messageId, language),
    null => null,
  };

  /// The language of [messageId] as far as the device can tell
  /// ([LanguageGuess]); [text] is read once per email.
  String? guess(int messageId, String Function() text) {
    if (_guesses.containsKey(messageId)) return _guesses[messageId];
    final guess = LanguageGuess.of(text());
    _guesses[messageId] = guess;
    if (_guesses.length > 200) _guesses.remove(_guesses.keys.first);
    return guess;
  }

  /// Whether the user put away the offer to translate [messageId].
  bool notNow(int messageId) => _notNow.contains(messageId);

  void dismiss(int messageId) {
    _notNow.add(messageId);
    notifyListeners();
  }

  /// Back to the email as written; its translation is kept.
  void showOriginal(int messageId) {
    if (_shown.remove(messageId) != null) notifyListeners();
  }

  /// Translates [mail] (the email [messageId]) into [language], or shows
  /// the translation already made, once [confirm] agrees to send it to
  /// the provider (`confirmAiSend`, which asks the user the first time).
  Future<void> translate(
    int messageId,
    PromptMail mail,
    String language, {
    required Future<bool> Function(AiFeatureProvider provider) confirm,
  }) async {
    final code = LanguageGuess.baseCode(language);
    final key = (messageId, code);
    if (_cache[key] case final existing?
        when existing.status != TranslationStatus.failed) {
      _shown[messageId] = code;
      notifyListeners();
      return;
    }
    final provider = await _ai.providerFor(AiFeatures.translate.id);
    final t = Translation._(messageId, code);
    if (provider == null) {
      _put(key, t)
        ..status = TranslationStatus.failed
        ..problem =
            'Translate isn\'t set up. Turn it on in Settings, AI assistant.';
      _shown[messageId] = code;
      notifyListeners();
      return;
    }
    t.recipient = provider.recipient;
    if (!await confirm(provider)) return;
    _put(key, t);
    _shown[messageId] = code;
    final cancel = t._cancel = AiCancel();
    notifyListeners();
    final request = MailTranslation.request(
      model: provider.model,
      mail: mail,
      languageCode: code,
    );
    try {
      await for (final event in provider.stream(request, cancel: cancel)) {
        switch (event) {
          case AiTextDelta(:final text):
            t._text.write(text);
          case AiCompleted(:final response):
            if (response.text.isNotEmpty) {
              t._text
                ..clear()
                ..write(response.text);
            }
            switch (response.stopReason) {
              case AiStopReason.refusal:
                t
                  ..status = TranslationStatus.failed
                  ..problem = const AiException(
                    AiProblem.refused,
                    '',
                  ).explain(t.recipient);
              case AiStopReason.maxTokens:
                t
                  ..status = TranslationStatus.done
                  ..cutOff = true;
              default:
                t.status = TranslationStatus.done;
            }
        }
        notifyListeners();
      }
      if (t.status == TranslationStatus.working) {
        t
          ..status = TranslationStatus.failed
          ..problem = const AiException(
            AiProblem.badResponse,
            '',
          ).explain(t.recipient);
      }
    } on AiException catch (e) {
      if (e.problem == AiProblem.cancelled) {
        if (identical(_cache[key], t)) {
          _cache.remove(key);
          if (_shown[messageId] == code) _shown.remove(messageId);
        }
      } else {
        t
          ..status = TranslationStatus.failed
          ..problem = e.explain(t.recipient);
      }
    } finally {
      t._cancel = null;
      notifyListeners();
    }
  }

  /// Stops a translation under way, and shows the original again.
  void stop(int messageId) {
    final t = shown(messageId);
    t?._cancel?.cancel();
    if (t != null && t.status == TranslationStatus.working) {
      _cache.remove((messageId, t.language));
      _shown.remove(messageId);
      notifyListeners();
    }
  }

  Translation _put((int, String) key, Translation t) {
    _cache
      ..remove(key)
      ..[key] = t;
    while (_cache.length > keep) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
      if (_shown[oldest.$1] == oldest.$2) _shown.remove(oldest.$1);
    }
    return t;
  }
}
