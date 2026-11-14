// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../app.dart' show appName;
import '../mail/summaries.dart';
import '../services/ai_assistant.dart';
import 'ai_feature_tiles.dart';
import 'app_icons.dart';
import 'page_scaffold.dart';

/// "AI assistant (your own key)": the providers and keys, the model
/// features use, each feature's switch, this month's use and cost, the
/// monthly limit and prices, and what is sent where.
final class AiSettingsPage extends StatelessWidget {
  const AiSettingsPage({super.key, required this.ai, this.summaries});

  final AiAssistant ai;

  /// For "Forget saved summaries".
  final MessageSummaries? summaries;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'AI assistant',
    body: ValueListenableBuilder(
      valueListenable: ai.changes,
      builder: (context, _, _) {
        final configured = ai.providerSettings.configured;
        final kept = summaries?.savedCount ?? 0;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Optional, and off until you turn it on. $appName has no '
                'server: with your own key, the email you ask about goes '
                'straight from this device to the provider you choose. '
                'Nothing reaches us.',
              ),
            ),
            const _Heading('Providers'),
            for (final kind in configured) _ProviderTile(ai: ai, kind: kind),
            ListTile(
              key: const ValueKey('ai-add-provider'),
              leading: const Icon(AppIcons.add),
              title: Text(
                configured.isEmpty ? 'Add your key' : 'Add another provider',
              ),
              subtitle: const Text(
                'Claude, GPT, Meta Muse, Gemini, or any OpenAI-compatible '
                'endpoint, such as a model on your own computer',
              ),
              onTap: () => AiProviderDialog.show(context, ai),
            ),
            if (configured.isNotEmpty) ...[
              const _Heading('Model'),
              _DefaultModelTile(ai: ai),
            ],
            const _Heading('Features'),
            for (final feature in AiFeatures.all)
              if (aiFeatureTiles[feature.id] case final tile?) tile(ai),
            if (kept > 0)
              ListTile(
                key: const ValueKey('ai-forget-summaries'),
                leading: const Icon(AppIcons.delete),
                title: const Text('Forget saved summaries'),
                subtitle: Text(
                  '$kept kept on this device, so they aren\'t sent again',
                ),
                onTap: () {
                  summaries!.forgetAll();
                  ai.changes.value++;
                },
              ),
            const _Heading('Use and cost'),
            AiUsageSummary(ai: ai),
            AiMonthlyLimitTile(ai: ai),
            ListTile(
              key: const ValueKey('ai-prices'),
              leading: const Icon(AppIcons.bill),
              title: const Text('Prices'),
              subtitle: const Text(
                'What each model costs, per million tokens, to work out '
                'the cost. Anthropic\'s are filled in.',
              ),
              trailing: const Icon(AppIcons.chevron),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => AiPricesPage(ai: ai)),
              ),
            ),
            const _Heading('What is sent where'),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Only when you use a feature, and only what that feature '
                'needs, such as the email you ask to summarise. It goes '
                'from this device straight to the provider you chose, with '
                'your key. Each feature asks once before it first sends '
                'anything.\n\n'
                'Your keys stay in this device\'s keychain and are never '
                'synced. Results are kept on this device only.\n\n'
                'The provider\'s own terms and privacy policy apply to '
                'what it receives: some keep requests for a while, for '
                'example to check for abuse. A model on your own computer '
                'or network keeps everything with you.',
              ),
            ),
          ],
        );
      },
    ),
  );
}

final class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// A provider that is set up: its key (only the end of it) or address,
/// and Remove.
final class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.ai, required this.kind});

  final AiAssistant ai;
  final AiProviderKind kind;

  Future<void> _remove(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${kind.label}?'),
        content: const Text(
          'Its key is deleted from this device. Features that used it stop '
          'until you choose another provider.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('ai-remove-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes == true) await ai.removeProvider(kind);
  }

  @override
  Widget build(BuildContext context) => _MaskedKey(
    ai: ai,
    kind: kind,
    builder: (masked) {
      final address = kind == AiProviderKind.custom
          ? ai.providerSettings.baseUrl(kind)?.toString()
          : null;
      return ListTile(
        key: ValueKey('ai-provider-${kind.id}'),
        leading: const Icon(AppIcons.apiKey),
        title: Text(kind.label),
        subtitle: Text(
          [?address, masked == null ? 'No key' : 'Key $masked'].join('\n'),
        ),
        onTap: () => AiProviderDialog.show(context, ai, kind: kind),
        trailing: IconButton(
          key: ValueKey('ai-remove-${kind.id}'),
          tooltip: 'Remove ${kind.label}',
          icon: const Icon(AppIcons.delete),
          onPressed: () => _remove(context),
        ),
      );
    },
  );
}

/// The end of [kind]'s key from the keychain, read again when settings
/// change, keeping the last one shown meanwhile (no flicker).
final class _MaskedKey extends StatefulWidget {
  const _MaskedKey({
    required this.ai,
    required this.kind,
    required this.builder,
  });

  final AiAssistant ai;
  final AiProviderKind kind;
  final Widget Function(String? masked) builder;

  @override
  State<_MaskedKey> createState() => _MaskedKeyState();
}

final class _MaskedKeyState extends State<_MaskedKey> {
  String? _masked;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_MaskedKey old) {
    super.didUpdateWidget(old);
    _load();
  }

  Future<void> _load() async {
    final masked = await widget.ai.maskedKey(widget.kind);
    if (mounted && masked != _masked) setState(() => _masked = masked);
  }

  @override
  Widget build(BuildContext context) => widget.builder(_masked);
}

/// Adds a provider (or replaces its key): the key, the address for a
/// custom endpoint, "Test key" (which lists the models the key can use)
/// and the model to use. Saved only once the test worked.
final class AiProviderDialog extends StatefulWidget {
  const AiProviderDialog({super.key, required this.ai, this.kind});

  final AiAssistant ai;

  /// The provider to change; null to pick one.
  final AiProviderKind? kind;

  static Future<void> show(
    BuildContext context,
    AiAssistant ai, {
    AiProviderKind? kind,
  }) => showDialog<void>(
    context: context,
    builder: (_) => AiProviderDialog(ai: ai, kind: kind),
  );

  @override
  State<AiProviderDialog> createState() => _AiProviderDialogState();
}

final class _AiProviderDialogState extends State<AiProviderDialog> {
  late AiProviderKind _kind =
      widget.kind ??
      AiProviderKind.values.firstWhere(
        (k) => !widget.ai.providerSettings.isConfigured(k),
        orElse: () => AiProviderKind.claude,
      );
  final _key = TextEditingController();
  final _address = TextEditingController();
  final _model = TextEditingController();
  bool _showKey = false;
  bool _busy = false;
  String? _error;
  List<AiModel>? _models;

  @override
  void initState() {
    super.initState();
    if (widget.kind == AiProviderKind.custom) {
      _address.text =
          widget.ai.providerSettings
              .baseUrl(AiProviderKind.custom)
              ?.toString() ??
          '';
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _address.dispose();
    _model.dispose();
    super.dispose();
  }

  void _changed() => setState(() {
    _models = null;
    _error = null;
  });

  /// The custom endpoint's address, or null if it isn't one.
  Uri? get _baseUrl {
    if (_kind != AiProviderKind.custom) return null;
    final uri = Uri.tryParse(_address.text.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri;
  }

  Future<void> _test() async {
    if (_kind == AiProviderKind.custom && _baseUrl == null) {
      setState(
        () => _error =
            'Enter the endpoint\'s address, such as '
            'http://localhost:11434/v1 or https://openrouter.ai/api/v1.',
      );
      return;
    }
    if (_kind.needsKey && _key.text.trim().isEmpty) {
      setState(() => _error = 'Paste your ${_kind.company} API key first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _models = null;
    });
    try {
      final models = await widget.ai.testKey(
        _kind,
        key: _key.text,
        baseUrl: _baseUrl,
      );
      if (!mounted) return;
      final current = widget.ai.features.defaultChoice;
      final preferred = [
        if (current != null && current.provider == _kind) current.model,
        ?_kind.defaultModel,
      ];
      setState(() {
        _busy = false;
        _models = models;
        if (models.isEmpty) {
          _error = 'The key works, but it offers no models.';
        }
        _model.text =
            preferred
                .where((id) => models.any((m) => m.id == id))
                .firstOrNull ??
            models.firstOrNull?.id ??
            '';
      });
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.explain(_kind.company ?? _baseUrl?.host ?? 'The endpoint');
      });
    }
  }

  Future<void> _save() async {
    final model = _model.text.trim();
    final ai = widget.ai;
    await ai.saveProvider(
      _kind,
      key: _key.text,
      baseUrl: _baseUrl,
      model: model.isEmpty ? null : model,
    );
    // The provider's key changed: its model is the one chosen here.
    if (model.isNotEmpty && ai.features.defaultChoice?.provider == _kind) {
      ai.setDefault(AiChoice(_kind, model));
    }
    if (mounted) Navigator.pop(context);
  }

  String get _keyHelp => switch (_kind) {
    AiProviderKind.claude =>
      'Create a key in your Anthropic Console account (API keys).',
    AiProviderKind.openai =>
      'Create a key in your OpenAI platform account (API keys).',
    AiProviderKind.meta =>
      'Create a key on Meta\'s developer site, dev.meta.ai (Model API).',
    AiProviderKind.google =>
      'Create a free key in Google AI Studio (aistudio.google.com, Get API '
          'key). The free tier has daily limits, and Google may use what '
          'you send on it to improve its products.',
    AiProviderKind.custom =>
      'Only if the endpoint needs one; a model on your own computer '
          'usually doesn\'t.',
  };

  @override
  Widget build(BuildContext context) {
    final models = _models;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.kind == null ? 'Add a provider' : 'Change ${_kind.label}',
      ),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.kind == null)
              DropdownButtonFormField<AiProviderKind>(
                isExpanded: true,
                key: const ValueKey('ai-provider-kind'),
                initialValue: _kind,
                decoration: const InputDecoration(
                  labelText: 'Provider',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final k in AiProviderKind.values)
                    DropdownMenuItem(value: k, child: Text(k.label)),
                ],
                onChanged: _busy
                    ? null
                    : (k) {
                        if (k == null) return;
                        _kind = k;
                        _model.clear();
                        _changed();
                      },
              ),
            if (_kind == AiProviderKind.custom) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('ai-address'),
                controller: _address,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                onChanged: (_) => _changed(),
                decoration: const InputDecoration(
                  labelText: 'Endpoint address',
                  hintText: 'https://openrouter.ai/api/v1',
                  helperText:
                      'Secure https, or http only to your own computer or '
                      'network',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('ai-key'),
              controller: _key,
              enabled: !_busy,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => _changed(),
              decoration: InputDecoration(
                labelText: _kind.needsKey ? 'API key' : 'API key (optional)',
                helperText: _keyHelp,
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _showKey ? 'Hide key' : 'Show key',
                  icon: Icon(
                    _showKey ? AppIcons.hidePassword : AppIcons.showPassword,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The key stays in this device\'s keychain. Requests are paid '
              'from your account with the provider.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('ai-test-key'),
                onPressed: _busy ? null : _test,
                icon: const Icon(AppIcons.apiKey, size: 18),
                label: const Text('Test key'),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: colors.error)),
            ],
            if (models != null && models.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(AppIcons.success, size: 18, color: colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The key works: ${models.length} '
                      'model${models.length == 1 ? '' : 's'}.',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownMenu<String>(
                key: const ValueKey('ai-model'),
                controller: _model,
                expandedInsets: EdgeInsets.zero,
                label: const Text('Model'),
                helperText:
                    'Larger models write better; smaller ones cost '
                    'less.',
                requestFocusOnTap: false,
                menuHeight: 320,
                dropdownMenuEntries: [
                  for (final m in models)
                    DropdownMenuEntry(value: m.id, label: m.name),
                ],
                onSelected: (id) => setState(() => _model.text = id ?? ''),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('ai-save-provider'),
          onPressed: _busy || models == null || models.isEmpty ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// The provider and model features use unless one has its own.
final class _DefaultModelTile extends StatelessWidget {
  const _DefaultModelTile({required this.ai});

  final AiAssistant ai;

  @override
  Widget build(BuildContext context) {
    final choice = ai.features.defaultChoice;
    final ready =
        choice != null && ai.providerSettings.isConfigured(choice.provider);
    return ListTile(
      key: const ValueKey('ai-default-model'),
      leading: const Icon(AppIcons.model),
      title: const Text('Provider and model'),
      subtitle: Text(
        ready
            ? '${choice.provider.label}, ${choice.model}'
            : 'Not chosen yet: features stay off until you choose',
      ),
      trailing: const Icon(AppIcons.chevron),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _DefaultModelDialog(ai: ai),
      ),
    );
  }
}

/// Picks the default provider and model, from the models the key can use
/// (or typed in, when the list can't be fetched).
final class _DefaultModelDialog extends StatefulWidget {
  const _DefaultModelDialog({required this.ai});

  final AiAssistant ai;

  @override
  State<_DefaultModelDialog> createState() => _DefaultModelDialogState();
}

final class _DefaultModelDialogState extends State<_DefaultModelDialog> {
  late AiProviderKind _kind;
  final _model = TextEditingController();
  List<AiModel>? _models;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final ai = widget.ai;
    final choice = ai.features.defaultChoice;
    final configured = ai.providerSettings.configured;
    _kind = choice != null && configured.contains(choice.provider)
        ? choice.provider
        : configured.first;
    if (choice?.provider == _kind) _model.text = choice!.model;
    _load();
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _models = null;
    });
    final kind = _kind;
    try {
      final models = await widget.ai.modelsOf(kind);
      if (!mounted || kind != _kind) return;
      setState(() {
        _busy = false;
        _models = models;
        if (_model.text.isEmpty) {
          _model.text =
              models.where((m) => m.id == kind.defaultModel).firstOrNull?.id ??
              models.firstOrNull?.id ??
              '';
        }
      });
    } on AiException catch (e) {
      if (!mounted || kind != _kind) return;
      setState(() {
        _busy = false;
        _models = const [];
        _error =
            '${e.explain(kind.company ?? 'The endpoint')} You can still type '
            'a model\'s name.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = widget.ai;
    final models = _models ?? const <AiModel>[];
    return AlertDialog(
      title: const Text('Provider and model'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'What the features use. Larger models write better; smaller '
              'ones are faster and cost less.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<AiProviderKind>(
              isExpanded: true,
              key: const ValueKey('ai-default-provider'),
              initialValue: _kind,
              decoration: const InputDecoration(
                labelText: 'Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final k in ai.providerSettings.configured)
                  DropdownMenuItem(value: k, child: Text(k.label)),
              ],
              onChanged: (k) {
                if (k == null || k == _kind) return;
                _kind = k;
                _model.clear();
                _load();
              },
            ),
            const SizedBox(height: 16),
            DropdownMenu<String>(
              key: const ValueKey('ai-default-model-menu'),
              controller: _model,
              expandedInsets: EdgeInsets.zero,
              label: const Text('Model'),
              menuHeight: 320,
              dropdownMenuEntries: [
                for (final m in models)
                  DropdownMenuEntry(value: m.id, label: m.name),
              ],
              onSelected: (id) => _model.text = id ?? _model.text,
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('ai-default-save'),
          onPressed: () {
            final model = _model.text.trim();
            if (model.isEmpty) return;
            ai.setDefault(AiChoice(_kind, model));
            Navigator.pop(context);
          },
          child: const Text('Use'),
        ),
      ],
    );
  }
}

/// Dollars as people read them.
String aiDollars(double dollars) => dollars > 0 && dollars < 0.01
    ? 'less than \$0.01'
    : '\$${dollars.toStringAsFixed(2)}';

String _tokens(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// This month's requests, tokens and cost, per provider and model.
final class AiUsageSummary extends StatelessWidget {
  const AiUsageSummary({super.key, required this.ai});

  final AiAssistant ai;

  @override
  Widget build(BuildContext context) {
    final spend = ai.ledger.spend(ai.prices);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      key: const ValueKey('ai-usage'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(AppIcons.usage),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  spend.calls == 0
                      ? 'Nothing used this month.'
                      : 'This month: ${aiDollars(spend.cost)} for '
                            '${spend.calls} '
                            'request${spend.calls == 1 ? '' : 's'}.',
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          ),
          for (final e in spend.entries)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Text(
                '${e.provider.company ?? 'Your endpoint'}, ${e.model}: '
                '${e.calls} request${e.calls == 1 ? '' : 's'}, '
                '${_tokens(e.usage.inputTokens)} tokens sent, '
                '${_tokens(e.usage.outputTokens)} received'
                '${switch (ai.prices.price(e.provider, e.model)) {
                  final p? => ', ${aiDollars(p.cost(e.usage))}',
                  null => ', price unknown',
                }}',
                style: muted,
              ),
            ),
          if (spend.unpricedCalls > 0)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Text(
                'Models without a price aren\'t in the cost or the limit: '
                'add their price under Prices.',
                style: muted,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 6),
            child: Text(
              'Counted on this device from what each provider reports. '
              'Your provider\'s bill is what counts.',
              style: muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// The monthly limit: once this month's cost reaches it, nothing more is
/// sent until next month.
final class AiMonthlyLimitTile extends StatelessWidget {
  const AiMonthlyLimitTile({super.key, required this.ai});

  final AiAssistant ai;

  Future<void> _edit(BuildContext context) async {
    final result = await showDialog<_Numbers>(
      context: context,
      builder: (_) => _NumbersDialog(
        title: 'Monthly limit',
        text:
            'When this month\'s cost reaches it, $appName sends nothing more '
            'until next month. Leave it empty for no limit.',
        fields: [('US dollars a month', ai.ledger.monthlyCap)],
        allowEmpty: true,
      ),
    );
    if (result case (reset: false, values: [final dollars])) {
      ai.setMonthlyCap(dollars);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cap = ai.ledger.monthlyCap;
    final reached = ai.ledger.capReached(ai.prices);
    return ListTile(
      key: const ValueKey('ai-cap'),
      leading: const Icon(AppIcons.bill),
      title: const Text('Monthly limit'),
      subtitle: Text(switch (cap) {
        null => 'No limit',
        final c when reached =>
          '${aiDollars(c)} a month: reached, nothing more is sent until '
              'next month',
        final c => '${aiDollars(c)} a month',
      }),
      trailing: const Icon(AppIcons.chevron),
      onTap: () => _edit(context),
    );
  }
}

/// What each model costs, per million tokens sent and received: the
/// models the user set up or used, Anthropic's filled in.
final class AiPricesPage extends StatelessWidget {
  const AiPricesPage({super.key, required this.ai});

  final AiAssistant ai;

  List<(AiProviderKind, String)> _models() {
    final seen = <String>{};
    return [
      for (final kind in AiProviderKind.values) ...[
        if (ai.providerSettings.isConfigured(kind) ||
            kind == AiProviderKind.claude)
          for (final m in ai.knownModels(kind))
            if (seen.add('${kind.id}/$m')) (kind, m),
      ],
      for (final e in ai.ledger.spend(ai.prices).entries)
        if (seen.add('${e.provider.id}/${e.model}')) (e.provider, e.model),
    ];
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: 'Prices',
    body: ValueListenableBuilder(
      valueListenable: ai.changes,
      builder: (context, _, _) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'In US dollars per million tokens (a token is about four '
              'letters), sent / received. Check your provider\'s price '
              'list; tap a model to change its price.',
            ),
          ),
          for (final (kind, model) in _models())
            ListTile(
              key: ValueKey('ai-price-${kind.id}/$model'),
              title: Text(model),
              subtitle: Text(
                '${kind.label}: ${switch (ai.prices.price(kind, model)) {
                  final p? => '\$${_number(p.inputPerMillion)} / '
                      '\$${_number(p.outputPerMillion)}'
                      '${ai.prices.isOwn(kind, model) ? ' (yours)' : ''}',
                  null => 'unknown',
                }}',
              ),
              onTap: () => _edit(context, kind, model),
            ),
        ],
      ),
    ),
  );

  static String _number(double n) => _NumbersDialog.number(n);

  Future<void> _edit(
    BuildContext context,
    AiProviderKind kind,
    String model,
  ) async {
    final price = ai.prices.price(kind, model);
    final result = await showDialog<_Numbers>(
      context: context,
      builder: (_) => _NumbersDialog(
        title: model,
        fields: [
          ('Per million tokens sent', price?.inputPerMillion),
          ('Per million tokens received', price?.outputPerMillion),
        ],
        canReset: ai.prices.isOwn(kind, model),
      ),
    );
    switch (result) {
      case null:
        return;
      case (reset: true, values: _):
        ai.setPrice(kind, model, null);
      case (reset: false, values: [final a?, final b?]):
        ai.setPrice(kind, model, AiPrice(a, b));
      default:
        return;
    }
  }
}

/// What a [_NumbersDialog] gives back: the numbers (null where a field
/// was left empty), or Reset.
typedef _Numbers = ({bool reset, List<double?> values});

/// Asks for amounts in dollars (the monthly limit, a model's prices).
final class _NumbersDialog extends StatefulWidget {
  const _NumbersDialog({
    required this.title,
    required this.fields,
    this.text,
    this.allowEmpty = false,
    this.canReset = false,
  });

  final String title;
  final String? text;

  /// Each field's label and value.
  final List<(String, double?)> fields;

  /// Whether a field may be left empty (no limit).
  final bool allowEmpty;
  final bool canReset;

  static String number(double n) =>
      n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toString();

  @override
  State<_NumbersDialog> createState() => _NumbersDialogState();
}

final class _NumbersDialogState extends State<_NumbersDialog> {
  late final _fields = [
    for (final (_, value) in widget.fields)
      TextEditingController(
        text: value == null ? '' : _NumbersDialog.number(value),
      ),
  ];
  bool _invalid = false;

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _save() {
    final values = <double?>[];
    for (final f in _fields) {
      final text = f.text.trim().replaceAll(',', '.').replaceAll(r'$', '');
      final value = double.tryParse(text);
      if ((text.isEmpty && !widget.allowEmpty) ||
          (text.isNotEmpty && (value == null || value < 0))) {
        setState(() => _invalid = true);
        return;
      }
      values.add(value);
    }
    Navigator.pop(context, (reset: false, values: values));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.text case final text?) ...[
          Text(text),
          const SizedBox(height: 12),
        ],
        for (final (i, (label, _)) in widget.fields.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          TextField(
            key: ValueKey('ai-number-$i'),
            controller: _fields[i],
            autofocus: i == 0,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              prefixText: '\$ ',
              labelText: label,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        if (_invalid) ...[
          const SizedBox(height: 12),
          Text(
            'Enter an amount such as 5 or 0.25.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    ),
    actions: [
      if (widget.canReset)
        TextButton(
          onPressed: () =>
              Navigator.pop(context, (reset: true, values: <double?>[])),
          child: const Text('Reset'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('ai-number-save'),
        onPressed: _save,
        child: const Text('Save'),
      ),
    ],
  );
}
