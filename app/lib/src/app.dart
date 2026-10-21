// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_setup/mail_setup.dart';

import 'services/app_services.dart';
import 'setup/setup_controller.dart';
import 'setup/setup_page.dart';
import 'ui/fmail_theme.dart';
import 'ui/mail_shell.dart';

/// Placeholder product name. The final name is still open, so it lives in
/// one place to make renaming easy.
const String appName = 'Fmail';

/// The app: opens the encrypted store, then shows setup or the home page.
class FmailApp extends StatelessWidget {
  const FmailApp({super.key, this.startup = AppStartup.open});

  /// Replaced in tests.
  final Future<StartupResult> Function() startup;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appName,
    debugShowCheckedModeBanner: false,
    theme: FmailTheme.light(),
    darkTheme: FmailTheme.dark(),
    home: _StartupGate(startup: startup),
  );
}

class _StartupGate extends StatefulWidget {
  const _StartupGate({required this.startup});

  final Future<StartupResult> Function() startup;

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  late Future<StartupResult> _result = _start();

  /// Starts up, reporting an unexpected failure to the console (and the
  /// screen) instead of losing it.
  Future<StartupResult> _start() =>
      widget.startup().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'fmail',
            context: ErrorDescription('while starting up'),
          ),
        );
        Error.throwWithStackTrace(error, stack);
      });

  void _retry() {
    final next = _start();
    setState(() {
      _result = next;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<StartupResult>(
    future: _result,
    builder: (context, snapshot) => switch (snapshot.data) {
      null when snapshot.hasError => _Problem(
        title: 'Fmail couldn\'t start',
        message:
            'Something unexpected went wrong. (${snapshot.error.runtimeType}: ${snapshot.error})',
        actionLabel: 'Try again',
        onAction: _retry,
      ),
      null => const Scaffold(body: Center(child: CircularProgressIndicator())),
      StartupReady(:final services) => _Home(services: services),
      StartupKeychainUnavailable() => _Problem(
        title: 'A keychain is needed',
        message:
            'Fmail stores passwords only in your system\'s keychain, and couldn\'t reach it. '
            'On Linux, make sure GNOME Keyring or KWallet is installed and unlocked, then try again.',
        actionLabel: 'Try again',
        onAction: _retry,
      ),
      StartupDataUnreadable(:final databasePath) => _Problem(
        title: 'Local data can\'t be opened',
        message:
            'Fmail\'s local data is encrypted, and its key is missing or doesn\'t match. Your mail is '
            'safe on the server. Starting fresh deletes the local copy (and any changes not yet sent); you '
            'will add your accounts again.',
        actionLabel: 'Start fresh',
        onAction: () async {
          await AppStartup.resetLocalData(databasePath);
          _retry();
        },
      ),
      StartupEncryptionUnavailable(:final detail) => _Problem(
        title: 'Encryption unavailable',
        message:
            'Fmail won\'t store mail without encryption, and the encryption library is missing. ($detail)',
      ),
    },
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.services});

  final AppServices services;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _adding = false;

  SetupController _newSetup() {
    final discovery = AccountDiscovery();
    const verifier = AccountVerifier();
    return SetupController(
      discover: discovery.discover,
      verify: verifier.verify,
      save: widget.services.addAccount,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasAccounts = widget.services.store.accounts.all().isNotEmpty;
    if (!hasAccounts || _adding) {
      return SetupPage(
        controller: _newSetup(),
        onDone: (_) => setState(() => _adding = false),
        onCancel: hasAccounts ? () => setState(() => _adding = false) : null,
      );
    }
    return MailShell(
      services: widget.services,
      onAddAccount: () => setState(() => _adding = true),
      onAccountsChanged: () => setState(() {}),
    );
  }

  @override
  void dispose() {
    unawaited(widget.services.dispose());
    super.dispose();
  }
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.lock_outline,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (actionLabel != null) ...[
                const SizedBox(height: 24),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
