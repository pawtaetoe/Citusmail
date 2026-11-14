// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../app.dart' show appName;
import '../services/ai_assistant.dart';
import 'ai_feature_tiles.dart';
import 'page_scaffold.dart';

/// "AI assistant (your own key)": the providers and keys, the default
/// model, each feature's switch, this month's use and the limit, and what
/// is sent where.
final class AiSettingsPage extends StatelessWidget {
  const AiSettingsPage({super.key, required this.ai});

  final AiAssistant ai;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'AI assistant',
    body: ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text(
            'Optional, and off until you turn it on. $appName has no server: '
            'with your own key, the email you ask about goes straight from '
            'this device to the provider you choose. Nothing reaches us.',
          ),
        ),
        for (final feature in AiFeatures.all)
          if (aiFeatureTiles[feature.id] case final tile?) tile(ai),
      ],
    ),
  );
}
