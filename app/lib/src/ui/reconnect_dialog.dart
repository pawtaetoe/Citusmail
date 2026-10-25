// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_store/mail_store.dart';

import '../app.dart' show appName;
import '../setup/reconnect.dart';
import 'link_opener.dart';

/// Asks for an account's new password, or runs its OAuth sign-in again.
/// Pops with true once the new secret is checked and saved.
class ReconnectDialog extends StatefulWidget {
  const ReconnectDialog({
    super.key,
    required this.account,
    required this.reconnector,
  });

  final Account account;
  final Reconnector reconnector;

  static Future<bool> show(
    BuildContext context,
    Account account,
    Reconnector reconnector,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) =>
            ReconnectDialog(account: account, reconnector: reconnector),
      ) ??
      false;

  @override
  State<ReconnectDialog> createState() => _ReconnectDialogState();
}

class _ReconnectDialogState extends State<ReconnectDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  Account get _account => widget.account;

  KnownProvider? get _known => KnownProvider.forImapHost(_account.imap.host);

  String get _providerName => switch (_account.oauthProvider) {
    final id? => OAuthProvider.byId(id)?.name ?? id,
    null => '',
  };

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await action();
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final oauth = _account.usesOAuth;
    final appPassword = _known?.appPasswordUrl;
    return AlertDialog(
      title: Text(oauth ? 'Sign in again' : 'Update password'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _account.email,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (oauth)
              Text(
                'Your browser opens $_providerName\'s page. Sign in as ${_account.email}; '
                '$appName never sees your password. Your mail stays as it is.',
              )
            else ...[
              TextField(
                controller: _password,
                enabled: !_busy,
                autofocus: true,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: appPassword == null
                      ? 'New password'
                      : 'New app password',
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
                onSubmitted: (_) => _submitPassword(),
              ),
              const SizedBox(height: 8),
              const Text(
                'It is checked with your mail server before it replaces the old one.',
              ),
              if (appPassword != null)
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(
                    'Create an app password (${Uri.parse(appPassword).host})',
                  ),
                  onPressed: () =>
                      LinkOpener.launch(context, Uri.parse(appPassword)),
                ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                oauth
                    ? 'Waiting for the sign-in in your browser…'
                    : 'Checking…',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : oauth
              ? () => _run(() => widget.reconnector.signInAgain(_account))
              : _submitPassword,
          child: Text(oauth ? 'Continue with $_providerName' : 'Save'),
        ),
      ],
    );
  }

  void _submitPassword() {
    if (_busy) return;
    _run(() => widget.reconnector.usePassword(_account, _password.text));
  }
}
