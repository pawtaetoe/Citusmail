// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import '../ai_errors.dart';
import '../ai_provider.dart';
import '../transport/ai_http.dart';

/// Makes the [AiProvider] for a configuration.
typedef AiProviderFactory = AiProvider Function(AiProviderConfig config);

abstract final class AiProviders {
  /// The adapter for [config.kind], reaching the network through [http]
  /// ([IoAiHttp] by default). Throws [AiException] with
  /// [AiProblem.notConfigured] for a custom endpoint without an address.
  static AiProvider create(AiProviderConfig config, {AiHttp? http}) =>
      throw const AiException(
        AiProblem.notConfigured,
        'provider adapters are not built yet',
      );
}
