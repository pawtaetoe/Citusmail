// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'ai_types.dart';

/// Where the assistant keeps its small, non-secret choices (the app's
/// encrypted settings). Keys are never stored here: they go to the
/// system keychain, like mail passwords.
abstract interface class AiStore {
  String? read(String key);
  void write(String key, String value);
  void delete(String key);
}

/// A provider and one of its models.
final class AiChoice {
  const AiChoice(this.provider, this.model);

  final AiProviderKind provider;

  /// An [AiModel.id].
  final String model;

  static AiChoice? fromJson(String? json) {
    if (json == null) return null;
    try {
      final map = jsonDecode(json);
      if (map is! Map<String, Object?>) return null;
      final provider = AiProviderKind.byId(map['provider'] as String?);
      final model = map['model'];
      if (provider == null || model is! String || model.isEmpty) return null;
      return AiChoice(provider, model);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  String toJson() => jsonEncode({'provider': provider.id, 'model': model});

  @override
  bool operator ==(Object other) =>
      other is AiChoice && other.provider == provider && other.model == model;

  @override
  int get hashCode => Object.hash(provider, model);

  @override
  String toString() => 'AiChoice(${provider.id}, $model)';
}

/// One thing the assistant can do. Every feature is off until the user
/// turns it on, and says plainly what it sends.
final class AiFeature {
  const AiFeature({
    required this.id,
    required this.title,
    required this.sentence,
    required this.sends,
  });

  /// Stable: settings are stored under it.
  final String id;
  final String title;

  /// What it does, in one sentence.
  final String sentence;

  /// What it sends to the provider, in one sentence (also in the
  /// first-use confirmation).
  final String sends;
}

/// The assistant's features and the user's choices for them: on or off
/// (off by default), and which provider and model each uses (the default
/// choice unless the feature has its own).
///
/// A later feature adds itself with one constant here and one entry in
/// [all].
final class AiFeatures {
  AiFeatures(this._store);

  final AiStore _store;

  /// "Summarise" in the reader: one email or a whole conversation.
  static const summaries = AiFeature(
    id: 'summaries',
    title: 'Summaries',
    sentence:
        'A short summary of an email or a whole conversation, with dates, '
        'amounts and anything asked of you, when you tap Summarise.',
    sends:
        'the email or conversation you ask about: senders, recipients, '
        'dates, subjects, the text and the names of attached files',
  );

  /// "Ask your mail" in search: a question answered from the few emails
  /// that match it best, found on the device.
  static const ask = AiFeature(
    id: 'ask',
    title: 'Ask your mail',
    sentence:
        'Search with a question, like "When does my flight leave?", and get '
        'a short answer from your own mail, with the emails it comes from.',
    sends:
        'your question and the few emails that match it best on this device '
        '(8, at most 15): their senders, dates, subjects and part of their '
        'text',
  );

  /// Every feature, in the order Settings shows them.
  static const all = <AiFeature>[summaries, ask];

  static AiFeature? byId(String id) => all.where((f) => f.id == id).firstOrNull;

  static const _defaultKey = 'ai.default';
  static String _onKey(String id) => 'ai.feature.$id';
  static String _choiceKey(String id) => 'ai.feature.$id.model';
  static String _confirmedKey(String id, AiProviderKind kind) =>
      'ai.confirmed.$id.${kind.id}';

  /// Whether the user turned [id] on (off by default).
  bool isOn(String id) => _store.read(_onKey(id)) == 'on';

  void setOn(String id, bool on) =>
      on ? _store.write(_onKey(id), 'on') : _store.delete(_onKey(id));

  /// The provider and model features use unless they have their own.
  AiChoice? get defaultChoice => AiChoice.fromJson(_store.read(_defaultKey));
  set defaultChoice(AiChoice? choice) => choice == null
      ? _store.delete(_defaultKey)
      : _store.write(_defaultKey, choice.toJson());

  /// [id]'s own provider and model, if the user picked one (a cheaper
  /// model for one feature, say).
  AiChoice? ownChoice(String id) =>
      AiChoice.fromJson(_store.read(_choiceKey(id)));

  void setOwnChoice(String id, AiChoice? choice) => choice == null
      ? _store.delete(_choiceKey(id))
      : _store.write(_choiceKey(id), choice.toJson());

  /// What [id] uses: its own choice, else the default.
  AiChoice? choiceFor(String id) => ownChoice(id) ?? defaultChoice;

  /// Whether the user already agreed that [id] sends mail to [recipient]
  /// (with [kind]); asked once, and again if the recipient changes.
  bool confirmed(String id, AiProviderKind kind, String recipient) =>
      _store.read(_confirmedKey(id, kind)) == recipient;

  void confirm(String id, AiProviderKind kind, String recipient) =>
      _store.write(_confirmedKey(id, kind), recipient);

  /// Forgets the confirmations for [kind] (when its provider is removed).
  void forgetConfirmations(AiProviderKind kind) {
    for (final f in all) {
      _store.delete(_confirmedKey(f.id, kind));
    }
  }
}

/// Which providers the user set up, and a custom endpoint's address.
/// Their keys are in the keychain, not here.
final class AiProviderSettings {
  AiProviderSettings(this._store);

  final AiStore _store;

  static const _key = 'ai.providers';

  Map<String, Object?> _read() {
    try {
      final value = jsonDecode(_store.read(_key) ?? '{}');
      return value is Map<String, Object?> ? value : {};
    } on FormatException {
      return {};
    }
  }

  /// The providers set up, in [AiProviderKind] order.
  List<AiProviderKind> get configured {
    final stored = _read();
    return [
      for (final kind in AiProviderKind.values)
        if (stored.containsKey(kind.id)) kind,
    ];
  }

  bool isConfigured(AiProviderKind kind) => _read().containsKey(kind.id);

  /// Where [kind]'s requests go: the custom endpoint's address, or the
  /// provider's own.
  Uri? baseUrl(AiProviderKind kind) {
    final entry = _read()[kind.id];
    if (entry is Map<String, Object?> && entry['baseUrl'] is String) {
      return Uri.tryParse(entry['baseUrl']! as String);
    }
    return kind.defaultBaseUrl;
  }

  void add(AiProviderKind kind, {Uri? baseUrl}) {
    final stored = _read();
    stored[kind.id] = {'baseUrl': ?baseUrl?.toString()};
    _store.write(_key, jsonEncode(stored));
  }

  void remove(AiProviderKind kind) {
    final stored = _read()..remove(kind.id);
    _store.write(_key, jsonEncode(stored));
  }
}
