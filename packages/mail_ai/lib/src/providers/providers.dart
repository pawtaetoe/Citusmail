// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../ai_errors.dart';
import '../ai_provider.dart';
import '../ai_types.dart';
import '../transport/ai_http.dart';
import 'anthropic_provider.dart';
import 'openai_compatible_provider.dart';

/// Makes the [AiProvider] for a configuration.
typedef AiProviderFactory = AiProvider Function(AiProviderConfig config);

abstract final class AiProviders {
  /// The adapter for [config.kind], reaching the network through [http]
  /// ([IoAiHttp] by default). Throws [AiException] with
  /// [AiProblem.notConfigured] for a custom endpoint without an address.
  static AiProvider create(AiProviderConfig config, {AiHttp? http}) {
    final client = http ?? IoAiHttp();
    final base = config.endpoint;
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const AiException(
        AiProblem.notConfigured,
        'the endpoint needs an address, like http://localhost:11434/v1',
      );
    }
    final key = config.apiKey?.trim() ?? '';
    if (config.kind.needsKey && key.isEmpty) {
      throw AiException(
        AiProblem.notConfigured,
        '${config.kind.label} needs a key',
      );
    }
    return switch (config.kind) {
      AiProviderKind.claude => AnthropicProvider(
        apiKey: key,
        http: client,
        baseUrl: base,
      ),
      _ => OpenAiCompatibleProvider(
        kind: config.kind,
        baseUrl: base,
        http: client,
        apiKey: key.isEmpty ? null : key,
      ),
    };
  }
}
