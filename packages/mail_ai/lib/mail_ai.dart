// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The optional AI assistant with the user's own key (off by default):
/// one [AiProvider] interface over Claude, GPT, Meta's Llama API and any
/// OpenAI-compatible endpoint; [MailPrompt], the one place mail becomes
/// (untrusted) prompt data; [AiFeatures], the per-feature switches and
/// model choices; and [AiUsageLedger] with [AiPriceTable] for tokens,
/// cost and the monthly limit.
library;

export 'src/ai_errors.dart';
export 'src/ai_provider.dart';
export 'src/ai_settings.dart';
export 'src/ai_types.dart';
export 'src/mail_prompt.dart';
export 'src/providers/anthropic_provider.dart';
export 'src/providers/openai_compatible_provider.dart';
export 'src/providers/providers.dart';
export 'src/transport/ai_http.dart';
export 'src/usage.dart';
