// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../services/ai_assistant.dart';
import 'settings_page.dart' show SettingExplained;

/// Builds a feature's tile for Settings.
typedef AiFeatureTileBuilder = Widget Function(AiAssistant ai);

/// Each AI feature's own setting, by [AiFeature.id], shown in Settings
/// (the "AI assistant (your own key)" group and its page) in the order of
/// [AiFeatures.all]. A new feature adds one line here; its search entry
/// in settings_catalog.dart has the id `ai-<feature id>`.
final aiFeatureTiles = <String, AiFeatureTileBuilder>{
  AiFeatures.summaries.id: (ai) =>
      AiFeatureSwitch(ai: ai, feature: AiFeatures.summaries),
  AiFeatures.writing.id: (ai) =>
      AiFeatureSwitch(ai: ai, feature: AiFeatures.writing),
  AiFeatures.actions.id: (ai) =>
      AiFeatureSwitch(ai: ai, feature: AiFeatures.actions),
  AiFeatures.translate.id: (ai) =>
      AiFeatureSwitch(ai: ai, feature: AiFeatures.translate),
  AiFeatures.quickReplies.id: (ai) =>
      AiFeatureSwitch(ai: ai, feature: AiFeatures.quickReplies),
};

/// A feature's on/off switch: off by default, and only usable once a
/// provider is set up. Says what the feature sends, and where.
final class AiFeatureSwitch extends StatelessWidget {
  const AiFeatureSwitch({super.key, required this.ai, required this.feature});

  final AiAssistant ai;
  final AiFeature feature;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ai.changes,
    builder: (context, _, _) {
      final choice = ai.features.choiceFor(feature.id);
      final ready =
          choice != null && ai.providerSettings.isConfigured(choice.provider);
      final to = switch (choice) {
        final c? when ready => c.provider.company ?? 'your own endpoint',
        _ => 'the provider you choose',
      };
      return SwitchListTile(
        key: ValueKey('ai-feature-${feature.id}'),
        title: Text(feature.title),
        subtitle: SettingExplained(
          ready ? feature.sentence : 'Add a provider and key first, above.',
          more:
              'Only when you ask, it sends ${feature.sends} to $to, '
              'with your key. Nothing else from your mailbox is sent.',
        ),
        value: ready && ai.features.isOn(feature.id),
        onChanged: ready ? (on) => ai.setOn(feature.id, on) : null,
      );
    },
  );
}
