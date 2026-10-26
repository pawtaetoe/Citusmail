// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_web/mail_web.dart';

import 'security/lock_screen.dart';
import 'services/app_services.dart';
import 'services/secret_store.dart';
import 'setup/oauth_browser.dart';
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
    showPerformanceOverlay: _performanceOverlay,
    theme: CitusmailTheme.light(),
    darkTheme: CitusmailTheme.dark(),
    // Above the navigator: the lock covers every page and dialog.
    builder: (context, child) {
      final app = LockGate(
        host: _lockHost,
        child: child ?? const SizedBox.shrink(),
      );
      return _performanceOverlay ? _FrameRate(child: app) : app;
    },
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

  SetupController _newSetup() {
    final discovery = AccountDiscovery();
    const verifier = AccountVerifier();
    final browser = OAuthBrowser(TokenClient(WebClient()));
    return SetupController(
      discover: discovery.discover,
      verify: verifier.verify,
      save: widget.services.addAccount,
      oauthSignIn: browser.signIn,
      verifyOAuth: (settings, token) =>
          verifier.verify(settings, token, oauth: true),
      saveOAuth: widget.services.addOAuthAccount,
      ownClient: OwnOAuthClients(widget.services.secrets).read,
      saveOwnClient: OwnOAuthClients(widget.services.secrets).save,
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

/// `CITUSMAIL_PERF_OVERLAY=1`: Flutter's frame-time graphs and a frames per
/// second counter, for checking smoothness on a given machine.
final bool _performanceOverlay =
    Platform.environment['CITUSMAIL_PERF_OVERLAY'] == '1';

/// Frames drawn in the last second, top right (only while something moves:
/// an idle app draws nothing).
final class _FrameRate extends StatefulWidget {
  const _FrameRate({required this.child});

  final Widget child;

  @override
  State<_FrameRate> createState() => _FrameRateState();
}

final class _FrameRateState extends State<_FrameRate> {
  final _frames = <Duration>[];
  int _fps = 0;
  int _slowest = 0;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final now = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
      _frames.removeWhere((t) => now - t > const Duration(seconds: 1));
      if (mounted) setState(() => _fps = _frames.length);
    });
  }

  void _onTimings(List<FrameTiming> timings) {
    final now = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    for (final t in timings) {
      _frames.add(now);
      final ms = t.totalSpan.inMilliseconds;
      if (ms > _slowest) _slowest = ms;
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    textDirection: TextDirection.ltr,
    children: [
      widget.child,
      Positioned(
        top: 4,
        right: 4,
        child: IgnorePointer(
          child: ColoredBox(
            color: const Color(0xCC000000),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '$_fps fps · slowest ${_slowest}ms',
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
