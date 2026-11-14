// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_store/mail_store.dart';

import 'secret_store.dart';

/// The assistant's settings in the app's encrypted settings. None of
/// them sync between devices: each device agrees to sending mail to a
/// provider itself.
final class _SettingsStore implements AiStore {
  const _SettingsStore(this._store);

  final MailStore _store;

  @override
  String? read(String key) => _store.settings.read(key);

  @override
  void write(String key, String value) => _store.settings.write(key, value);

  @override
  void delete(String key) => _store.settings.delete(key);
}

/// The optional AI assistant, with the user's own key (off by default).
///
/// Which providers are set up and how each feature is set lives in the
/// settings; keys live in the system keychain like mail passwords.
/// Features ask [providerFor] for their provider, which is null unless
/// the user turned that feature on and its provider is set up.
final class AiAssistant {
  AiAssistant(
    MailStore store,
    this._secrets, {
    AiProviderFactory? providers,
    DateTime Function()? now,
  }) : _settings = _SettingsStore(store),
       _create = providers ?? AiProviders.create {
    features = AiFeatures(_settings);
    providerSettings = AiProviderSettings(_settings);
    prices = AiPriceTable(_settings);
    ledger = AiUsageLedger(_settings, now: now);
  }

  final SecretStore _secrets;
  final AiStore _settings;
  final AiProviderFactory _create;

  /// On or off per feature, and the provider and model each uses.
  late final AiFeatures features;

  /// The providers set up (their keys are in the keychain).
  late final AiProviderSettings providerSettings;

  /// Prices per model, which the user can change.
  late final AiPriceTable prices;

  /// Tokens used this month and the monthly limit.
  late final AiUsageLedger ledger;

  /// Changes whenever a setting changes, so what shows them (the
  /// reader's Summarise button, Settings) reads them again.
  final changes = ValueNotifier<int>(0);

  void _changed() => changes.value++;

  /// The keychain entry with [kind]'s key.
  static String keychainKey(AiProviderKind kind) => 'ai-key-${kind.id}';

  /// Whether [featureId] is on and has a provider to use: what decides
  /// whether its buttons show at all.
  bool isOn(String featureId) {
    if (!features.isOn(featureId)) return false;
    final choice = features.choiceFor(featureId);
    return choice != null && providerSettings.isConfigured(choice.provider);
  }

  /// Turns [featureId] on or off.
  void setOn(String featureId, bool on) {
    features.setOn(featureId, on);
    _changed();
  }

  /// The provider and model [featureId] uses, or null when the feature
  /// is off or nothing is set up for it (or its key is gone).
  Future<AiFeatureProvider?> providerFor(String featureId) async {
    final feature = AiFeatures.byId(featureId);
    if (feature == null || !isOn(featureId)) return null;
    final choice = features.choiceFor(featureId)!;
    final provider = await _provider(choice.provider);
    if (provider == null) return null;
    return AiFeatureProvider._(this, feature, provider, choice.model);
  }

  Future<AiProvider?> _provider(AiProviderKind kind) async {
    if (!providerSettings.isConfigured(kind)) return null;
    final key = await _secrets.read(keychainKey(kind));
    if (kind.needsKey && (key == null || key.isEmpty)) return null;
    try {
      return _create(
        AiProviderConfig(
          kind: kind,
          apiKey: key,
          baseUrl: providerSettings.baseUrl(kind),
        ),
      );
    } on AiException {
      return null;
    }
  }

  /// Lists the models [key] can use with [kind] (at [baseUrl] for a
  /// custom endpoint), without saving anything: the "Test key" button.
  /// Throws [AiException].
  Future<List<AiModel>> testKey(
    AiProviderKind kind, {
    String? key,
    Uri? baseUrl,
  }) => _create(
    AiProviderConfig(kind: kind, apiKey: key?.trim(), baseUrl: baseUrl),
  ).listModels();

  /// The models of a provider that is set up. Throws [AiException].
  Future<List<AiModel>> modelsOf(AiProviderKind kind) async {
    final provider = await _provider(kind);
    if (provider == null) {
      throw AiException(AiProblem.notConfigured, '${kind.label} isn\'t set up');
    }
    return provider.listModels();
  }

  /// Saves [kind] with [key] (in the keychain) and, for a custom
  /// endpoint, its [baseUrl]. The first provider becomes the default,
  /// with [model].
  Future<void> saveProvider(
    AiProviderKind kind, {
    String? key,
    Uri? baseUrl,
    String? model,
  }) async {
    final trimmed = key?.trim() ?? '';
    if (trimmed.isEmpty) {
      await _secrets.delete(keychainKey(kind));
    } else {
      await _secrets.write(keychainKey(kind), trimmed);
    }
    providerSettings.add(
      kind,
      baseUrl: kind == AiProviderKind.custom ? baseUrl : null,
    );
    // A new address must be agreed to again.
    features.forgetConfirmations(kind);
    if (model != null && features.defaultChoice == null) {
      features.defaultChoice = AiChoice(kind, model);
    }
    _changed();
  }

  /// Removes [kind] and its key; features that used it have no provider
  /// until another is chosen.
  Future<void> removeProvider(AiProviderKind kind) async {
    await _secrets.delete(keychainKey(kind));
    providerSettings.remove(kind);
    features.forgetConfirmations(kind);
    if (features.defaultChoice?.provider == kind) {
      features.defaultChoice = null;
    }
    for (final f in AiFeatures.all) {
      if (features.ownChoice(f.id)?.provider == kind) {
        features.setOwnChoice(f.id, null);
      }
    }
    _changed();
  }

  /// Sets the provider and model features use by default.
  void setDefault(AiChoice choice) {
    features.defaultChoice = choice;
    _changed();
  }

  /// Sets the monthly spending limit (null: none).
  void setMonthlyCap(double? dollars) {
    ledger.monthlyCap = dollars;
    _changed();
  }

  /// Removes every key (with "Forget everything" or a reset).
  Future<void> forgetKeys() async {
    for (final kind in AiProviderKind.values) {
      await _secrets.delete(keychainKey(kind));
    }
  }
}

/// A feature's provider and model, for one use: checks the monthly limit
/// before each request and records the tokens each one used, so no
/// feature can forget either.
final class AiFeatureProvider {
  AiFeatureProvider._(this._assistant, this.feature, this.provider, this.model);

  final AiAssistant _assistant;
  final AiFeature feature;
  final AiProvider provider;

  /// The [AiModel.id] the user chose for the feature.
  final String model;

  AiProviderKind get kind => provider.kind;

  /// Who receives what is sent ("Anthropic", or the endpoint's host).
  String get recipient => provider.recipient;

  /// Whether the user still has to agree, once, that this feature sends
  /// mail to [recipient].
  bool get needsConfirmation =>
      !_assistant.features.confirmed(feature.id, kind, recipient);

  /// The user agreed.
  void confirm() => _assistant.features.confirm(feature.id, kind, recipient);

  /// [AiProvider.stream], within the monthly limit, with the usage
  /// recorded. Throws [AiException] with [AiProblem.capReached] when this
  /// month's limit is reached.
  Stream<AiEvent> stream(AiRequest request, {AiCancel? cancel}) async* {
    _assistant.ledger.checkCap(_assistant.prices);
    await for (final event in provider.stream(request, cancel: cancel)) {
      if (event is AiCompleted) {
        _assistant.ledger.record(kind, request.model, event.response.usage);
        _assistant._changed();
      }
      yield event;
    }
  }

  /// [stream], waiting for the whole answer.
  Future<AiResponse> complete(AiRequest request, {AiCancel? cancel}) async {
    await for (final event in stream(request, cancel: cancel)) {
      if (event is AiCompleted) return event.response;
    }
    throw const AiException(AiProblem.badResponse, 'the answer ended early');
  }
}
