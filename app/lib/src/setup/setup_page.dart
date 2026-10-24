// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import '../ui/fmail_theme.dart';
import '../ui/link_opener.dart';
import 'setup_controller.dart';

/// The add-account flow. Calls [onDone] with the saved account.
class SetupPage extends StatefulWidget {
  const SetupPage({
    super.key,
    required this.controller,
    required this.onDone,
    this.onCancel,
  });

  final SetupController controller;
  final void Function(Account account) onDone;

  /// Shown as a close button when there is somewhere to go back to.
  final VoidCallback? onCancel;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final state = widget.controller.state;
    if (state is SetupDone) widget.onDone(state.account);
    setState(() {});
  }

  Future<bool> _askMozilla(String domain) async {
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ask Mozilla\'s database?'),
        content: Text(
          '$appName couldn\'t find the settings itself. Mozilla keeps a public list of mail settings.\n\n'
          'Only the domain "$domain" is sent to Mozilla, never your email address.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Don\'t ask'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ask Mozilla'),
          ),
        ],
      ),
    );
    return allowed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add account'),
        automaticallyImplyLeading: false,
        actions: [
          if (widget.onCancel != null)
            IconButton(
              onPressed: widget.onCancel,
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: switch (controller.state) {
                  EnteringCredentials(:final error) => _CredentialsForm(
                    key: const ValueKey('credentials'),
                    initialEmail: controller.email,
                    error: error,
                    canSignInWith: controller.canSignInWith,
                    providerFor: controller.providerFor,
                    onSubmit: (email, password, name) => controller.start(
                      email: email,
                      password: password,
                      displayName: name,
                      askMozillaConsent: _askMozilla,
                    ),
                    onOAuth: (provider, email, name) => controller.signInWith(
                      provider,
                      email: email,
                      displayName: name,
                    ),
                  ),
                  SigningIn(:final provider) => _Busy(
                    key: const ValueKey('signing-in'),
                    text:
                        'Sign in on ${provider.name}\'s page in your browser, then come back '
                        'here.',
                  ),
                  Discovering(:final step) => _Busy(
                    key: const ValueKey('discovering'),
                    text: SetupText.step(step),
                  ),
                  ReviewingSettings(:final settings) => _ReviewSettings(
                    key: const ValueKey('review'),
                    settings: settings,
                    onContinue: () => controller.useSettings(settings),
                    onEdit: () => controller.editSettings(settings),
                  ),
                  EditingSettings(:final prefill, :final notice) =>
                    _SettingsForm(
                      key: const ValueKey('edit'),
                      email: controller.email,
                      prefill: prefill,
                      notice: notice,
                      onSubmit: controller.useSettings,
                      onBack: controller.restart,
                    ),
                  Verifying() => const _Busy(
                    key: ValueKey('verifying'),
                    text: 'Signing in to check the settings…',
                  ),
                  VerificationFailed(:final settings, :final result) => _Failed(
                    key: const ValueKey('failed'),
                    settings: settings,
                    result: result,
                    onEdit: () => controller.editSettings(settings),
                    onRestart: controller.restart,
                    onUseSuggested: result.suggestedHost == null
                        ? null
                        : () => controller.useSuggestedHost(
                            settings,
                            result.role!,
                            result.suggestedHost!,
                          ),
                  ),
                  SetupDone() => const _Busy(
                    key: ValueKey('done'),
                    text: 'Account added.',
                  ),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CredentialsForm extends StatefulWidget {
  const _CredentialsForm({
    super.key,
    required this.initialEmail,
    required this.onSubmit,
    required this.onOAuth,
    required this.canSignInWith,
    required this.providerFor,
    this.error,
  });

  final String initialEmail;
  final String? error;
  final void Function(String email, String password, String name) onSubmit;
  final void Function(OAuthProvider provider, String email, String name)
  onOAuth;
  final bool Function(OAuthProvider provider) canSignInWith;
  final OAuthProvider? Function(String email) providerFor;

  @override
  State<_CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends State<_CredentialsForm> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _showPassword = false;

  /// The provider the typed address must sign in with, if any.
  OAuthProvider? _provider;

  /// A built-in provider for the typed address (Gmail: app passwords).
  KnownProvider? _known;

  @override
  void initState() {
    super.initState();
    _provider = widget.providerFor(_email.text);
    _known = KnownProvider.forEmail(_email.text);
    _email.addListener(() {
      final provider = widget.providerFor(_email.text);
      final known = KnownProvider.forEmail(_email.text);
      if (provider != _provider || known != _known) {
        setState(() {
          _provider = provider;
          _known = known;
        });
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Where to create an app password, when the address needs one.
  String? get _appPassword => _known?.appPasswordUrl;

  void _submit() {
    if (!_form.currentState!.validate()) return;
    if (_provider case final provider?) {
      widget.onOAuth(provider, _email.text, _name.text);
    } else {
      widget.onSubmit(_email.text, _password.text, _name.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: CitusMark(size: 36),
          ),
          const SizedBox(height: 20),
          Text(
            'Sign in to your email',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            '$appName connects directly to your mail provider. Your password is stored only in this '
            'device\'s keychain.',
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _email,
            decoration: const InputDecoration(
              labelText: 'Email address',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            validator: (v) =>
                RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v?.trim() ?? '')
                ? null
                : 'Enter an email address',
          ),
          if (_provider case final provider?) ...[
            const SizedBox(height: 12),
            Text(
              widget.canSignInWith(provider)
                  ? '${provider.name} asks you to sign in on its own page. Your browser opens '
                        'for that; $appName never sees your password.'
                  : '${provider.name} accounts need ${provider.name} sign-in, which this copy '
                        'of $appName can\'t do yet.',
            ),
          ] else ...[
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: !_showPassword,
              autofillHints: const [AutofillHints.password],
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _appPassword == null ? 'Password' : 'App password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? 'Hide password' : 'Show password',
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
              validator: (v) => (v ?? '').isEmpty
                  ? (_appPassword == null
                        ? 'Enter your password'
                        : 'Enter an app password')
                  : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            if (_known case final known? when known.needsAppPassword) ...[
              const SizedBox(height: 8),
              Text(SetupText.appPasswordHint(known)),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('create-app-password'),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(
                    'Create an app password '
                    '(${Uri.parse(known.appPasswordUrl!).host})',
                  ),
                  onPressed: () => LinkOpener.launch(
                    context,
                    Uri.parse(known.appPasswordUrl!),
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Your name (optional)',
              border: OutlineInputBorder(),
              helperText: 'Shown to people you write to',
            ),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 16),
            Text(
              widget.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _provider == null || widget.canSignInWith(_provider!)
                ? _submit
                : null,
            child: Text(
              _provider == null
                  ? 'Continue'
                  : 'Continue with ${_provider!.name}',
            ),
          ),
        ],
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 48),
      const CircularProgressIndicator(),
      const SizedBox(height: 24),
      Text(text, textAlign: TextAlign.center),
    ],
  );
}

class _ServerSummary extends StatelessWidget {
  const _ServerSummary({required this.label, required this.server});

  final String label;
  final ServerCandidate server;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.dns_outlined),
    title: Text('$label: ${server.host}'),
    subtitle: Text(
      'Port ${server.port} · ${SetupText.security(server.security)}',
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warning ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.warning_amber_rounded : Icons.info_outline,
            color: warning
                ? scheme.onErrorContainer
                : scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: warning
                    ? scheme.onErrorContainer
                    : scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewSettings extends StatelessWidget {
  const _ReviewSettings({
    super.key,
    required this.settings,
    required this.onContinue,
    required this.onEdit,
  });

  final DiscoveredSettings settings;
  final VoidCallback onContinue;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Settings found', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text('For ${settings.email}, ${SetupText.source(settings.source)}.'),
      const SizedBox(height: 16),
      for (final warning in settings.warnings)
        _Notice(text: SetupText.warning(warning, settings), warning: true),
      _ServerSummary(label: 'Incoming (IMAP)', server: settings.imap),
      _ServerSummary(label: 'Outgoing (SMTP)', server: settings.smtp),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.person_outline),
        title: Text('User name: ${settings.username}'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: onContinue,
        child: Text(
          settings.needsConfirmation ? 'I\'ve checked, continue' : 'Continue',
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: onEdit, child: const Text('Edit settings')),
    ],
  );
}

class _Failed extends StatelessWidget {
  const _Failed({
    super.key,
    required this.settings,
    required this.result,
    required this.onEdit,
    required this.onRestart,
    this.onUseSuggested,
  });

  final DiscoveredSettings settings;
  final VerificationResult result;
  final VoidCallback onEdit;
  final VoidCallback onRestart;
  final VoidCallback? onUseSuggested;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Couldn\'t sign in',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 16),
      _Notice(text: SetupText.problem(result, settings), warning: true),
      if (onUseSuggested != null) ...[
        FilledButton(
          onPressed: onUseSuggested,
          child: Text('Use ${result.suggestedHost} instead'),
        ),
        const SizedBox(height: 8),
      ],
      if (result.problem == VerificationProblem.appPasswordRequired)
        FilledButton(
          onPressed: onRestart,
          child: const Text('Enter an app password'),
        )
      else if (result.problem == VerificationProblem.credentials)
        FilledButton(
          onPressed: onRestart,
          child: const Text('Enter the password again'),
        )
      else
        OutlinedButton(onPressed: onRestart, child: const Text('Start over')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: onEdit, child: const Text('Edit settings')),
    ],
  );
}

/// Manual settings. Defaults follow the most common layout for the domain.
class _SettingsForm extends StatefulWidget {
  const _SettingsForm({
    super.key,
    required this.email,
    required this.onSubmit,
    required this.onBack,
    this.prefill,
    this.notice,
  });

  final String email;
  final DiscoveredSettings? prefill;
  final String? notice;
  final void Function(DiscoveredSettings settings) onSubmit;
  final VoidCallback onBack;

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  final _form = GlobalKey<FormState>();
  late final String _domain = widget.email.substring(
    widget.email.lastIndexOf('@') + 1,
  );
  late final _imapHost = TextEditingController(
    text: widget.prefill?.imap.host ?? 'imap.$_domain',
  );
  late final _imapPort = TextEditingController(
    text: '${widget.prefill?.imap.port ?? 993}',
  );
  late var _imapSecurity =
      widget.prefill?.imap.security ?? ConnectionSecurity.implicitTls;
  late final _smtpHost = TextEditingController(
    text: widget.prefill?.smtp.host ?? 'smtp.$_domain',
  );
  late final _smtpPort = TextEditingController(
    text: '${widget.prefill?.smtp.port ?? 465}',
  );
  late var _smtpSecurity =
      widget.prefill?.smtp.security ?? ConnectionSecurity.implicitTls;
  late final _username = TextEditingController(
    text: widget.prefill?.username ?? widget.email,
  );

  static final _host = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
  );

  @override
  void dispose() {
    for (final c in [_imapHost, _imapPort, _smtpHost, _smtpPort, _username]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validateHost(String? v) =>
      _host.hasMatch(v?.trim() ?? '') ? null : 'Enter a server name';

  String? _validatePort(String? v) {
    final port = int.tryParse(v?.trim() ?? '');
    return port != null && port > 0 && port < 65536
        ? null
        : 'Enter a port number';
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    widget.onSubmit(
      DiscoveredSettings(
        email: widget.email,
        imap: ServerCandidate(
          _imapHost.text.trim().toLowerCase(),
          int.parse(_imapPort.text.trim()),
          _imapSecurity,
        ),
        smtp: ServerCandidate(
          _smtpHost.text.trim().toLowerCase(),
          int.parse(_smtpPort.text.trim()),
          _smtpSecurity,
        ),
        username: _username.text.trim(),
        source: DiscoverySource.manual,
      ),
    );
  }

  Widget _server(
    String title,
    TextEditingController host,
    TextEditingController port,
    ConnectionSecurity security,
    void Function(ConnectionSecurity) onSecurity,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextFormField(
          controller: host,
          decoration: const InputDecoration(
            labelText: 'Server',
            border: OutlineInputBorder(),
          ),
          validator: _validateHost,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: TextFormField(
                controller: port,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: _validatePort,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<ConnectionSecurity>(
                initialValue: security,
                decoration: const InputDecoration(
                  labelText: 'Security',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final s in ConnectionSecurity.values)
                    DropdownMenuItem(
                      value: s,
                      child: Text(SetupText.security(s)),
                    ),
                ],
                onChanged: (s) => setState(() => onSecurity(s!)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Server settings',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        if (widget.notice != null) _Notice(text: widget.notice!),
        const _Notice(
          text:
              '$appName only connects with encryption. Unencrypted servers are not offered.',
        ),
        _server(
          'Incoming (IMAP)',
          _imapHost,
          _imapPort,
          _imapSecurity,
          (s) => _imapSecurity = s,
        ),
        const SizedBox(height: 24),
        _server(
          'Outgoing (SMTP)',
          _smtpHost,
          _smtpPort,
          _smtpSecurity,
          (s) => _smtpSecurity = s,
        ),
        const SizedBox(height: 24),
        TextFormField(
          controller: _username,
          decoration: const InputDecoration(
            labelText: 'User name',
            border: OutlineInputBorder(),
          ),
          validator: (v) =>
              (v ?? '').trim().isEmpty ? 'Enter your user name' : null,
          autocorrect: false,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _submit,
          child: const Text('Check and continue'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: widget.onBack, child: const Text('Back')),
      ],
    ),
  );
}
