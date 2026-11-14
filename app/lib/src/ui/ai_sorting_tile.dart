// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../services/ai_assistant.dart';
import '../services/ai_sorter.dart';
import 'settings_page.dart' show SettingExplained;

/// "Sorting backup" in Settings: its switch, how many emails at most each
/// time mail is checked, and the last problem. As it runs by itself
/// (not when the user asks), turning it on first asks the user to agree
/// to what is sent, and where.
final class AiSortingTile extends StatelessWidget {
  const AiSortingTile({super.key, required this.ai});

  final AiAssistant ai;

  static const feature = AiFeatures.sorting;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ai.changes,
    builder: (context, _, _) {
      final sorter = AiSorter.of(ai);
      final choice = ai.features.choiceFor(feature.id);
      final ready =
          choice != null && ai.providerSettings.isConfigured(choice.provider);
      final on = ready && ai.features.isOn(feature.id);
      final to = switch (choice) {
        final c? when ready => c.provider.company ?? 'your own endpoint',
        _ => 'the provider you choose',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: ValueKey('ai-feature-${feature.id}'),
            title: Text(feature.title),
            subtitle: SettingExplained(
              ready ? feature.sentence : 'Add a provider and key first, above.',
              more:
                  'After new mail comes, it sends ${feature.sends} to $to, '
                  'with your key. Nothing else from your mailbox is sent. '
                  'The assistant can only choose a section: it cannot '
                  'reply, delete or move anything else. Each email is '
                  'asked about once, and only if it came in the last day.',
            ),
            value: on,
            onChanged: ready ? (value) => _turn(context, value) : null,
          ),
          if (on && sorter != null) ...[
            _Agreement(ai: ai),
            ListTile(
              title: const Text('At most, each time mail is checked'),
              trailing: DropdownButton<int>(
                key: const ValueKey('ai-sorting-per-sync'),
                value: AiSorter.perSyncChoices.contains(sorter.perSync)
                    ? sorter.perSync
                    : AiSorter.defaultPerSync,
                items: [
                  for (final n in AiSorter.perSyncChoices)
                    DropdownMenuItem(value: n, child: Text('$n emails')),
                ],
                onChanged: (n) {
                  if (n != null) sorter.perSync = n;
                },
              ),
            ),
            ValueListenableBuilder(
              valueListenable: sorter.problem,
              builder: (context, problem, _) => problem == null
                  ? const SizedBox.shrink()
                  : ListTile(
                      key: const ValueKey('ai-sorting-problem'),
                      title: const Text('Last time, it could not sort'),
                      subtitle: Text(problem),
                    ),
            ),
          ],
        ],
      );
    },
  );

  Future<void> _turn(BuildContext context, bool value) async {
    if (!value) {
      ai.setOn(feature.id, false);
      return;
    }
    ai.setOn(feature.id, true);
    final provider = await ai.providerFor(feature.id);
    if (provider == null || !provider.needsConfirmation) return;
    if (!context.mounted) return;
    final agreed = await confirm(context, ai, provider);
    if (!agreed) ai.setOn(feature.id, false);
  }

  /// Asks once whether new mail may be sent to [provider]'s recipient;
  /// records the answer. Returns whether the user agreed.
  static Future<bool> confirm(
    BuildContext context,
    AiAssistant ai,
    AiFeatureProvider provider,
  ) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Send new mail to ${provider.recipient}?'),
        content: Text(
          'Sorting backup works by itself, after new mail comes. It sends '
          '${feature.sends} to ${provider.recipient}, with your key. '
          'Nothing else from your mailbox is sent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const ValueKey('ai-sorting-agree'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    if (agreed ?? false) {
      provider.confirm();
      // Settings show it, and what came meanwhile is sorted.
      ai.changes.value++;
      AiSorter.of(ai)?.request();
      return true;
    }
    return false;
  }
}

/// On, but not agreed to for the provider in use (it was changed): says
/// so, with a button to agree. Nothing is sent until then.
final class _Agreement extends StatelessWidget {
  const _Agreement({required this.ai});

  final AiAssistant ai;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: ai.providerFor(AiSortingTile.feature.id),
    builder: (context, snapshot) {
      final provider = snapshot.data;
      if (provider == null || !provider.needsConfirmation) {
        return const SizedBox.shrink();
      }
      return ListTile(
        key: const ValueKey('ai-sorting-waiting'),
        title: Text('Waiting for your OK to send to ${provider.recipient}'),
        trailing: TextButton(
          onPressed: () => AiSortingTile.confirm(context, ai, provider),
          child: const Text('Review'),
        ),
      );
    },
  );
}
