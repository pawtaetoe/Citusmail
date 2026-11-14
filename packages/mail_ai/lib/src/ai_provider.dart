// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'ai_errors.dart';
import 'ai_types.dart';

/// One AI service, with the user's key: what every feature uses.
///
/// Errors are [AiException]s, typed by [AiProblem]: a bad key, rate
/// limits (with the wait the provider asked for), refusals, network
/// problems, mail too long for the model, and so on.
abstract class AiProvider {
  AiProvider();

  AiProviderKind get kind;

  /// Who receives what is sent, for "Sent to ..." notes: the company, or
  /// the custom endpoint's host.
  String get recipient;

  /// The models this key can use, from the provider's models list (so
  /// names are never hard-coded and stay current). Also the "Test key"
  /// check: a bad key fails with [AiProblem.badKey].
  Future<List<AiModel>> listModels({AiCancel? cancel});

  /// Sends [request] and gives the answer's text as it is written,
  /// then [AiCompleted] with the whole answer and its token usage. A
  /// refusal ends with [AiCompleted] whose stop reason is
  /// [AiStopReason.refusal] (any partial text included). Cancelling the
  /// subscription, or [cancel], closes the connection.
  Stream<AiEvent> stream(AiRequest request, {AiCancel? cancel});

  /// [stream], waiting for the whole answer.
  Future<AiResponse> complete(AiRequest request, {AiCancel? cancel}) async {
    await for (final event in stream(request, cancel: cancel)) {
      if (event is AiCompleted) return event.response;
    }
    throw const AiException(AiProblem.badResponse, 'the answer ended early');
  }
}

/// Where a provider is reached, and with which key.
final class AiProviderConfig {
  const AiProviderConfig({required this.kind, this.apiKey, this.baseUrl});

  final AiProviderKind kind;

  /// Null or empty for a custom endpoint without one (a local model).
  final String? apiKey;

  /// For [AiProviderKind.custom] (required there); others use their
  /// [AiProviderKind.defaultBaseUrl].
  final Uri? baseUrl;

  Uri? get endpoint => baseUrl ?? kind.defaultBaseUrl;
}
