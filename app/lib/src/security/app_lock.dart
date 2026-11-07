// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mail_store/mail_store.dart';

import '../services/secret_store.dart';
import 'pin_hasher.dart';

/// How long the app may be left before it locks.
enum LockTimeout {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes');

  const LockTimeout(this.duration, this.label);

  final Duration duration;
  final String label;
}

/// The system's own way to confirm the user: fingerprint or face on
/// Android, Windows Hello on Windows. Only ever answers yes or no.
abstract interface class Biometrics {
  /// Whether the device can confirm the user this way right now.
  Future<bool> isAvailable();

  /// Asks the system to confirm the user; true if it did.
  Future<bool> authenticate(String reason);

  /// What to call it ("fingerprint or face", "Windows Hello").
  String get name;
}

/// [Biometrics] through the `local_auth` plugin. Linux has none.
final class SystemBiometrics implements Biometrics {
  SystemBiometrics() : _auth = LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  String get name =>
      Platform.isWindows ? 'Windows Hello' : 'fingerprint or face';

  @override
  Future<bool> isAvailable() async {
    if (!(Platform.isAndroid || Platform.isWindows)) return false;
    try {
      return await _auth.isDeviceSupported() &&
          (Platform.isWindows || await _auth.canCheckBiometrics);
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Android: the fingerprint or face only, not the device PIN (the
        // app has its own). Windows Hello decides its own methods.
        biometricOnly: Platform.isAndroid,
      );
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }
}

/// The result of a PIN attempt.
sealed class UnlockResult {
  const UnlockResult();
}

final class Unlocked extends UnlockResult {
  const Unlocked();
}

/// Wrong PIN; [wait] is how long until the next try is allowed (zero if
/// at once).
final class WrongPin extends UnlockResult {
  const WrongPin(this.wait);

  final Duration wait;
}

/// Too many wrong tries: no attempt was made.
final class MustWait extends UnlockResult {
  const MustWait(this.wait);

  final Duration wait;
}

/// The app lock: a PIN (and optionally the system's biometrics) between
/// the user's mail and anyone else holding the device.
///
/// It is a gate, not encryption: background sync and notifications keep
/// working while locked (mail is already encrypted at rest with a key in
/// the system keychain). The PIN's hash lives in the keychain; settings
/// and the count of wrong tries in the encrypted store, so restarting the
/// app does not reset the wait after too many wrong PINs.
///
/// The wait is measured on the device's uptime where there is one
/// (Android's `elapsedRealtime`, which keeps counting while the phone
/// sleeps and which nobody can set), so moving the date forward does not
/// shorten it. After a restart the uptime starts over, and so does the
/// wait: a restart never makes it shorter. Where no uptime is available
/// (desktops), the wall clock is used.
final class AppLock with WidgetsBindingObserver {
  AppLock(
    this._store,
    this._secrets, {
    Biometrics? biometrics,
    DateTime Function()? now,
    Future<int?> Function()? elapsedMillis,
    bool? desktop,
    this.pinRounds = PinHasher.iterations,
  }) : biometrics = biometrics ?? SystemBiometrics(),
       _now = now ?? DateTime.now,
       _elapsed = elapsedMillis ?? _systemElapsedMillis,
       _desktop = desktop ?? (Platform.isLinux || Platform.isWindows);

  final MailStore _store;
  final SecretStore _secrets;
  final Biometrics biometrics;
  final DateTime Function() _now;

  /// Milliseconds since the device started, or null where the platform
  /// has no such clock.
  final Future<int?> Function() _elapsed;
  final bool _desktop;

  /// PBKDF2 rounds for new PINs (lower only in tests).
  final int pinRounds;

  /// The keychain entry with the PIN's hash.
  static const pinKey = 'app-lock-pin';

  static const _enabledKey = 'lock.enabled';
  static const _timeoutKey = 'lock.timeout';
  static const _biometricsKey = 'lock.biometrics';
  static const _failuresKey = 'lock.failures';

  /// When the wait ends, as a wall-clock time (for showing a countdown,
  /// and the only measure where there is no uptime clock).
  static const _untilKey = 'lock.until';

  /// When the wait ends and when it was set, in device uptime.
  static const _untilElapsedKey = 'lock.untilElapsed';
  static const _elapsedAtKey = 'lock.elapsedAt';

  /// The length of the current wait, to start it over after a restart.
  static const _waitKey = 'lock.wait';

  /// Shortest and longest PIN.
  static const minLength = 4;
  static const maxLength = 16;

  /// Wrong PINs allowed before waits start.
  static const freeTries = 5;

  /// Whether the mail must be hidden behind the lock screen.
  final locked = ValueNotifier<bool>(false);

  /// Whether the lock is turned on (for widgets that offer "Lock now").
  final isOn = ValueNotifier<bool>(false);

  /// Whether the app is in the background (or, on phones, being
  /// switched): its content is covered so the app switcher shows nothing.
  final covered = ValueNotifier<bool>(false);

  DateTime? _leftAt;
  bool _observing = false;

  /// The Android side (see MainActivity.kt).
  static const _android = MethodChannel('citusmail/background');

  /// Android's `SystemClock.elapsedRealtime()`; null elsewhere, or off a
  /// device (tests).
  static Future<int?> _systemElapsedMillis() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _android.invokeMethod<int>('elapsedRealtime');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Hides the app from the app switcher's pictures while the lock is on.
  Future<void> _applyPrivacy() async {
    if (!Platform.isAndroid) return;
    try {
      await _android.invokeMethod<void>('setPrivate', enabled);
    } on MissingPluginException {
      // Not on a device (tests).
    } on PlatformException {
      // Older Android: the cover shown while in the background remains.
    }
  }

  /// Whether the lock is on, readable without an [AppLock] (the
  /// background isolate uses it to hide notification content).
  static bool isEnabledIn(MailStore store) =>
      store.settings.read(_enabledKey) == 'on';

  bool get enabled => isEnabledIn(_store);

  LockTimeout get timeout => LockTimeout.values.firstWhere(
    (t) => t.name == _store.settings.read(_timeoutKey),
    orElse: () => LockTimeout.oneMinute,
  );
  set timeout(LockTimeout value) =>
      _store.settings.write(_timeoutKey, value.name);

  bool get useBiometrics => _store.settings.read(_biometricsKey) == 'on';
  set useBiometrics(bool on) =>
      _store.settings.write(_biometricsKey, on ? 'on' : 'off');

  /// Starts watching the app's lifecycle; locks at once if the lock is on.
  Future<void> start() async {
    if (enabled && PinHash.decode(await _secrets.read(pinKey)) == null) {
      // The keychain lost the PIN: without it nobody could unlock.
      _store.settings.write(_enabledKey, 'off');
    }
    locked.value = enabled;
    isOn.value = enabled;
    await _applyPrivacy();
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  /// Stops watching the lifecycle. The notifiers are left to the garbage
  /// collector: the lock gate may still be listening during this frame.
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      lifecycleChanged(state);

  /// Reacts to the app leaving or coming back (public for tests).
  void lifecycleChanged(AppLifecycleState state) {
    if (!enabled) {
      covered.value = false;
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        final left = _leftAt;
        _leftAt = null;
        if (left != null && !_now().isBefore(left.add(timeout.duration))) {
          locked.value = true;
        }
        covered.value = false;
      case AppLifecycleState.inactive:
        // On desktops this only means another window has the focus.
        if (!_desktop) covered.value = true;
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _leftAt ??= _now();
        covered.value = true;
        if (timeout == LockTimeout.immediately) locked.value = true;
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Locks now (the "Lock" button).
  void lockNow() {
    if (enabled) locked.value = true;
  }

  // --------------------------------------------------------------- PIN

  /// Whether [pin] can be a PIN: digits only, [minLength] to [maxLength].
  static bool isValidPin(String pin) =>
      RegExp('^[0-9]{$minLength,$maxLength}\$').hasMatch(pin);

  /// Turns the lock on with [pin] (or changes the PIN).
  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) throw ArgumentError.value('***', 'pin', 'not a PIN');
    final hash = await PinHasher.hash(pin, rounds: pinRounds);
    await _secrets.write(pinKey, hash.encode());
    _store.settings.write(_enabledKey, 'on');
    isOn.value = true;
    _resetFailures();
    await _applyPrivacy();
  }

  /// Turns the lock off, if [pin] is right.
  Future<UnlockResult> disable(String pin) async {
    final result = await _check(pin);
    if (result is Unlocked) {
      _store.settings.write(_enabledKey, 'off');
      isOn.value = false;
      await _secrets.delete(pinKey);
      locked.value = false;
      covered.value = false;
      await _applyPrivacy();
    }
    return result;
  }

  /// Unlocks with the PIN.
  Future<UnlockResult> unlock(String pin) async {
    final result = await _check(pin);
    if (result is Unlocked) locked.value = false;
    return result;
  }

  /// Checks [pin] (for unlocking, or before changing settings), counting
  /// wrong tries.
  Future<UnlockResult> verify(String pin) => _check(pin);

  /// Unlocks with the system's biometrics, if turned on and available.
  Future<bool> unlockWithBiometrics(String reason) async {
    if (!useBiometrics || await currentWait() > Duration.zero) return false;
    if (!await biometrics.isAvailable()) return false;
    if (!await biometrics.authenticate(reason)) return false;
    _resetFailures();
    locked.value = false;
    return true;
  }

  /// How long until another PIN may be tried, by the wall clock: what the
  /// lock screen counts down. The gate itself asks [currentWait], which
  /// prefers the device's uptime and corrects this value from it.
  Duration get waitRemaining {
    final until = int.tryParse(_store.settings.read(_untilKey) ?? '');
    if (until == null) return Duration.zero;
    final left = DateTime.fromMillisecondsSinceEpoch(
      until,
      isUtc: true,
    ).difference(_now().toUtc());
    return left.isNegative ? Duration.zero : left;
  }

  /// How long until another PIN may be tried, measured on the device's
  /// uptime where there is one (so a changed date does not count), else
  /// by the wall clock.
  Future<Duration> currentWait() async {
    final byClock = waitRemaining;
    final elapsed = await _elapsed();
    final untilElapsed = int.tryParse(
      _store.settings.read(_untilElapsedKey) ?? '',
    );
    final elapsedAt = int.tryParse(_store.settings.read(_elapsedAtKey) ?? '');
    if (elapsed == null || untilElapsed == null || elapsedAt == null) {
      return byClock;
    }
    if (elapsed < elapsedAt) {
      // The device restarted since the wait was set: its uptime started
      // over, and the wait starts over too, so a restart never shortens it.
      final wait = Duration(
        milliseconds: int.tryParse(_store.settings.read(_waitKey) ?? '') ?? 0,
      );
      _startWait(wait, elapsed);
      return wait;
    }
    final left = Duration(milliseconds: untilElapsed - elapsed);
    if (left <= Duration.zero) return Duration.zero;
    if (left != byClock) {
      // The date was changed: keep the countdown shown in step with the
      // real wait.
      _store.settings.write(
        _untilKey,
        '${_now().toUtc().add(left).millisecondsSinceEpoch}',
      );
    }
    return left;
  }

  Future<UnlockResult> _check(String pin) async {
    final wait = await currentWait();
    if (wait > Duration.zero) return MustWait(wait);
    final stored = PinHash.decode(await _secrets.read(pinKey));
    if (stored != null && await PinHasher.verify(pin, stored)) {
      _resetFailures();
      return const Unlocked();
    }
    final failures =
        (int.tryParse(_store.settings.read(_failuresKey) ?? '') ?? 0) + 1;
    _store.settings.write(_failuresKey, '$failures');
    final delay = delayAfter(failures);
    if (delay > Duration.zero) _startWait(delay, await _elapsed());
    return WrongPin(delay);
  }

  /// Starts a wait of [delay] from now, in uptime too when [elapsed] (the
  /// device's uptime now) is known.
  void _startWait(Duration delay, int? elapsed) {
    _store.settings.write(
      _untilKey,
      '${_now().toUtc().add(delay).millisecondsSinceEpoch}',
    );
    _store.settings.write(_waitKey, '${delay.inMilliseconds}');
    if (elapsed == null) {
      _store.settings.delete(_untilElapsedKey);
      _store.settings.delete(_elapsedAtKey);
    } else {
      _store.settings.write(
        _untilElapsedKey,
        '${elapsed + delay.inMilliseconds}',
      );
      _store.settings.write(_elapsedAtKey, '$elapsed');
    }
  }

  /// The wait after [failures] wrong PINs in a row: none for the first
  /// [freeTries], then 30 seconds, 1, 5 and 15 minutes, then an hour.
  static Duration delayAfter(int failures) => switch (failures - freeTries) {
    < 0 => Duration.zero,
    0 => const Duration(seconds: 30),
    1 => const Duration(minutes: 1),
    2 => const Duration(minutes: 5),
    3 => const Duration(minutes: 15),
    _ => const Duration(hours: 1),
  };

  void _resetFailures() {
    _store.settings.delete(_failuresKey);
    _store.settings.delete(_untilKey);
    _store.settings.delete(_untilElapsedKey);
    _store.settings.delete(_elapsedAtKey);
    _store.settings.delete(_waitKey);
  }
}
