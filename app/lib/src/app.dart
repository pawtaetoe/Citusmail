// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';

import 'pairing/receive_accounts_page.dart';
import 'security/lock_screen.dart';
import 'services/app_services.dart';
import 'setup/new_setup.dart';
import 'setup/setup_controller.dart';
import 'setup/setup_page.dart';
import 'ui/citusmail_theme.dart';
import 'ui/mail_shell.dart';

/// The product name, in one place so user-facing text never hard-codes it.
const String appName = 'Citusmail';

/// The app: opens the encrypted store, then shows setup or the home page.
class CitusmailApp extends StatefulWidget {
  const CitusmailApp({super.key, this.startup = AppStartup.open});

  /// Replaced in tests.
  final Future<StartupResult> Function() startup;

  @override
  State<CitusmailApp> createState() => _CitusmailAppState();
}

class _CitusmailAppState extends State<CitusmailApp> {
  final _lockHost = LockHost();

  @override
  void dispose() {
    _lockHost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appName,
    debugShowCheckedModeBanner: false,
    theme: CitusmailTheme.light(),
    darkTheme: CitusmailTheme.dark(),
    // Above the navigator: the lock covers every page and dialog.
    builder: (context, child) =>
        LockGate(host: _lockHost, child: child ?? const SizedBox.shrink()),
    home: _StartupGate(startup: widget.startup, lockHost: _lockHost),
  );
}

class _StartupGate extends StatefulWidget {
  const _StartupGate({required this.startup, required this.lockHost});

  final Future<StartupResult> Function() startup;
  final LockHost lockHost;

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  late Future<StartupResult> _result = _start();

  /// Starts up, reporting an unexpected failure to the console (and the
  /// screen) instead of losing it. The lock is handed to the gate before
  /// the mail screen is ever built, so mail never shows unlocked.
  Future<StartupResult> _start() => widget
      .startup()
      .then((result) {
        if (result case StartupReady(:final services)) {
          widget.lockHost.attach(
            services.lock,
            reset: () async {
              // The mail screen goes first (nothing may read the store
              // while it is wiped), then everything is removed, then a
              // fresh start.
              final restarted = Completer<StartupResult>();
              setState(() {
                _result = restarted.future;
              });
              await services.resetEverything();
              restarted.complete(_start());
            },
          );
        } else {
          widget.lockHost.clear();
        }
        return result;
      })
      .catchError((Object error, StackTrace stack) {
        widget.lockHost.clear();
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'citusmail',
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
        title: '$appName couldn\'t start',
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
            '$appName stores passwords only in your system\'s keychain, and couldn\'t reach it. '
            'On Linux, make sure GNOME Keyring or KWallet is installed and unlocked, then try again.',
        actionLabel: 'Try again',
        onAction: _retry,
      ),
      StartupDataUnreadable(:final databasePath) => _Problem(
        title: 'Local data can\'t be opened',
        message:
            '$appName\'s local data is encrypted, and its key is missing or doesn\'t match. Your mail is '
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
            '$appName won\'t store mail without encryption, and the encryption library is missing. ($detail)',
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

  /// The add-account flow on screen, kept across rebuilds: the app
  /// rebuilds this widget for many reasons (theme, lock, window focus),
  /// and a new flow would throw the user back to the first step.
  SetupController? _setup;

  void _closeSetup() => setState(() {
    _adding = false;
    _setup = null;
  });

  SetupController _newSetup() => newSetupController(widget.services);

  /// Desktops: adds the accounts from the user's phone (QR code).
  Future<void> _addFromPhone() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReceiveAccountsPage(services: widget.services),
      ),
    );
    if (!mounted) return;
    if (widget.services.store.accounts.all().isNotEmpty) _closeSetup();
  }

  @override
  Widget build(BuildContext context) {
    final hasAccounts = widget.services.store.accounts.all().isNotEmpty;
    if (!hasAccounts || _adding) {
      return SetupPage(
        controller: _setup ??= _newSetup(),
        onDone: (_) => _closeSetup(),
        onCancel: hasAccounts ? _closeSetup : null,
        onAddFromPhone: ReceiveAccountsPage.supported ? _addFromPhone : null,
      );
    }
    return MailShell(
      services: widget.services,
      onAddAccount: () => setState(() => _adding = true),
      onAccountsChanged: () => setState(() {}),
    );
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
