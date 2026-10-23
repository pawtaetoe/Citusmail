// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show appName;
import 'app_lock.dart';

/// Which lock is in charge, set by the home screen once the app's
/// services exist. The gate sits above the navigator, so it covers every
/// page and dialog, not just the mail screen.
final class LockHost extends ChangeNotifier {
  AppLock? _lock;
  Future<void> Function()? _reset;
  bool _resetting = false;

  AppLock? get lock => _lock;

  /// "Forgot PIN" is wiping the app: everything stays covered until a
  /// fresh start attaches a new lock.
  bool get resetting => _resetting;

  void attach(AppLock lock, {required Future<void> Function() reset}) {
    _lock = lock;
    _reset = reset;
    _resetting = false;
    notifyListeners();
  }

  /// No lock (start-up didn't get as far as the mail).
  void clear() {
    _lock = null;
    _reset = null;
    _resetting = false;
    notifyListeners();
  }

  Future<void> reset() async {
    final reset = _reset;
    if (reset == null) return;
    _resetting = true;
    notifyListeners();
    await reset();
  }
}

/// Shows the app, or the lock screen instead of it. While locked, the app
/// stays alive underneath (nothing is lost) but isn't drawn, can't take
/// the keyboard focus, and is hidden from screen readers. While the app
/// is in the background, a plain cover hides it from the app switcher.
final class LockGate extends StatelessWidget {
  const LockGate({super.key, required this.host, required this.child});

  final LockHost host;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: host,
    builder: (context, _) {
      if (host.resetting) {
        return Stack(
          fit: StackFit.expand,
          children: [
            _hidden(child, hide: true),
            const ColoredBox(
              color: Colors.black26,
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        );
      }
      final lock = host.lock;
      if (lock == null) return child;
      return ListenableBuilder(
        listenable: Listenable.merge([lock.locked, lock.covered]),
        builder: (context, _) {
          final locked = lock.locked.value;
          final covered = lock.covered.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              _hidden(child, hide: locked),
              if (locked)
                // Its own navigator: the app's is hidden underneath, and
                // the lock screen's dialog and text field need one.
                HeroControllerScope.none(
                  child: Navigator(
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => LockScreen(lock: lock, host: host),
                    ),
                  ),
                )
              else if (covered)
                const _Cover(),
            ],
          );
        },
      );
    },
  );
}

/// [child], or with [hide] kept alive but not drawn, focusable or read
/// out. The same shape either way, so hiding never rebuilds the app.
Widget _hidden(Widget child, {required bool hide}) => TickerMode(
  enabled: !hide,
  child: ExcludeFocus(
    excluding: hide,
    child: ExcludeSemantics(
      excluding: hide,
      child: Offstage(offstage: hide, child: child),
    ),
  ),
);

/// What the app switcher shows while the lock is on.
final class _Cover extends StatelessWidget {
  const _Cover();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: Icon(
        Icons.lock_outline,
        size: 48,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// Asks for the PIN (or the system's biometrics).
final class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.lock, required this.host});

  final AppLock lock;
  final LockHost host;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

final class _LockScreenState extends State<LockScreen> {
  final _pin = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _busy = false;
  bool _biometricsReady = false;
  Timer? _tick;

  AppLock get _lock => widget.lock;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    unawaited(_prepareBiometrics());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pin.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _prepareBiometrics() async {
    if (!_lock.useBiometrics) return;
    final ready = await _lock.biometrics.isAvailable();
    if (!mounted || !ready) return;
    setState(() => _biometricsReady = true);
    // Offered at once, as people expect; the PIN stays available.
    await _biometric();
  }

  Future<void> _biometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _lock.unlockWithBiometrics('Unlock $appName');
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) _focus.requestFocus();
  }

  /// Refreshes the wait message every second while a wait is on.
  void _startCountdown() {
    _tick?.cancel();
    if (_lock.waitRemaining == Duration.zero) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() {});
      if (_lock.waitRemaining == Duration.zero) timer.cancel();
    });
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    if (_busy || pin.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await _lock.unlock(pin);
    if (!mounted) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _error = switch (result) {
        Unlocked() => null,
        WrongPin(:final wait) when wait > Duration.zero => 'Wrong PIN.',
        WrongPin() => 'Wrong PIN. Try again.',
        MustWait() => null,
      };
    });
    _startCountdown();
    if (result is! Unlocked) _focus.requestFocus();
  }

  Future<void> _forgot() async {
    final reset = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reset $appName?'),
        content: const Text(
          'Without the PIN, the only way in is to start over. This removes '
          'your accounts and the mail stored on this device. Your mail stays '
          'on your mail server, and comes back when you add your accounts '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (reset == true) await widget.host.reset();
  }

  static String _clock(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wait = _lock.waitRemaining;
    final waiting = wait > Duration.zero;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '$appName is locked',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pin,
                    focusNode: _focus,
                    autofocus: !_lock.useBiometrics,
                    enabled: !waiting && !_busy,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    maxLength: AppLock.maxLength,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    autofillHints: const <String>[],
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                      border: const OutlineInputBorder(),
                      errorText: waiting
                          ? 'Too many wrong PINs. Try again in ${_clock(wait)}.'
                          : _error,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: waiting || _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Unlock'),
                  ),
                  if (_biometricsReady) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: waiting || _busy ? null : _biometric,
                      icon: const Icon(Icons.fingerprint),
                      label: Text('Use ${_lock.biometrics.name}'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _busy ? null : _forgot,
                    child: const Text('Forgot PIN?'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
