// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/security/app_lock.dart';
import 'package:fmail/src/security/pin_hasher.dart';

import 'support/test_app.dart';

final class _FakeBiometrics implements Biometrics {
  bool available = true;
  bool answer = true;
  int asked = 0;

  @override
  String get name => 'fingerprint';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return answer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestApp app;
  late DateTime now;
  late _FakeBiometrics biometrics;
  late AppLock lock;

  AppLock newLock({bool desktop = false}) => AppLock(
    app.store,
    app.services.secrets,
    biometrics: biometrics,
    now: () => now,
    desktop: desktop,
    pinRounds: 1000,
  );

  setUp(() async {
    app = await TestApp.create();
    now = DateTime.utc(2026, 10, 23, 12);
    biometrics = _FakeBiometrics();
    lock = newLock();
  });

  tearDown(() async {
    lock.dispose();
    await app.dispose();
  });

  test('off by default; a PIN turns it on and locks at start', () async {
    await lock.start();
    expect(lock.enabled, isFalse);
    expect(lock.locked.value, isFalse);

    await lock.setPin('482910');
    expect(lock.enabled, isTrue);
    expect(lock.isOn.value, isTrue);
    expect(lock.timeout, LockTimeout.oneMinute, reason: 'the default');
    final stored = await app.services.secrets.read(AppLock.pinKey);
    expect(stored, startsWith('pbkdf2-sha256\$'));
    expect(stored, isNot(contains('482910')));

    final restarted = newLock();
    await restarted.start();
    expect(restarted.locked.value, isTrue);
    restarted.dispose();
  });

  test('PINs are 4 to 16 digits', () async {
    for (final pin in ['123', 'abcd', '12 34', '1' * 17, '']) {
      expect(AppLock.isValidPin(pin), isFalse, reason: pin);
      expect(() => lock.setPin(pin), throwsArgumentError);
    }
    expect(AppLock.isValidPin('1234'), isTrue);
    expect(AppLock.isValidPin('1' * 16), isTrue);
  });

  test(
    'right PIN unlocks; wrong PINs bring growing waits that persist',
    () async {
      await lock.setPin('482910');
      await lock.start();
      for (var i = 1; i < AppLock.freeTries; i++) {
        expect(await lock.unlock('000000'), isA<WrongPin>());
        expect(lock.waitRemaining, Duration.zero);
      }
      final fifth = await lock.unlock('000000');
      expect((fifth as WrongPin).wait, const Duration(seconds: 30));
      // Even the right PIN must wait now, and a restart doesn't help.
      expect(await lock.unlock('482910'), isA<MustWait>());
      expect(newLock().waitRemaining, const Duration(seconds: 30));
      expect(lock.locked.value, isTrue);

      now = now.add(const Duration(seconds: 31));
      expect(
        (await lock.unlock('111111') as WrongPin).wait,
        const Duration(minutes: 1),
      );
      now = now.add(const Duration(minutes: 2));
      expect(await lock.unlock('482910'), isA<Unlocked>());
      expect(lock.locked.value, isFalse);
      expect(lock.waitRemaining, Duration.zero);
      // The count starts over after a success.
      expect((await lock.verify('000000') as WrongPin).wait, Duration.zero);
    },
  );

  test('the waits grow to an hour', () {
    expect(
      [for (var f = 1; f <= 10; f++) AppLock.delayAfter(f).inSeconds],
      [0, 0, 0, 0, 30, 60, 300, 900, 3600, 3600],
    );
  });

  test('locks after leaving for the chosen time', () async {
    await lock.setPin('482910');
    await lock.start();
    await lock.unlock('482910');

    lock.lifecycleChanged(AppLifecycleState.paused);
    expect(lock.covered.value, isTrue, reason: 'hidden from the app switcher');
    now = now.add(const Duration(seconds: 30));
    lock.lifecycleChanged(AppLifecycleState.resumed);
    expect(lock.locked.value, isFalse, reason: 'back within a minute');
    expect(lock.covered.value, isFalse);

    lock.lifecycleChanged(AppLifecycleState.hidden);
    now = now.add(const Duration(seconds: 61));
    lock.lifecycleChanged(AppLifecycleState.resumed);
    expect(lock.locked.value, isTrue);

    await lock.unlock('482910');
    lock.timeout = LockTimeout.immediately;
    lock.lifecycleChanged(AppLifecycleState.hidden);
    expect(lock.locked.value, isTrue, reason: 'locked before leaving');
  });

  test('on desktops, another window taking the focus covers nothing', () async {
    lock.lifecycleChanged(AppLifecycleState.inactive);
    expect(lock.covered.value, isFalse, reason: 'the lock is off');

    await lock.setPin('482910');
    lock.lifecycleChanged(AppLifecycleState.inactive);
    expect(lock.covered.value, isTrue, reason: 'phones: the app switcher');

    // Same settings (one store), but a desktop.
    final desktop = newLock(desktop: true);
    desktop.lifecycleChanged(AppLifecycleState.inactive);
    expect(desktop.covered.value, isFalse);
    desktop.lifecycleChanged(AppLifecycleState.hidden);
    expect(desktop.covered.value, isTrue, reason: 'minimised');
    desktop.dispose();
  });

  test('biometrics unlock only when turned on and allowed', () async {
    await lock.setPin('482910');
    await lock.start();
    expect(await lock.unlockWithBiometrics('Unlock'), isFalse, reason: 'off');
    expect(biometrics.asked, 0);

    lock.useBiometrics = true;
    biometrics.answer = false;
    expect(await lock.unlockWithBiometrics('Unlock'), isFalse);
    expect(lock.locked.value, isTrue);
    biometrics.answer = true;
    expect(await lock.unlockWithBiometrics('Unlock'), isTrue);
    expect(lock.locked.value, isFalse);

    // Not during a wait for wrong PINs.
    lock.lockNow();
    for (var i = 0; i < AppLock.freeTries; i++) {
      await lock.unlock('000000');
    }
    final before = biometrics.asked;
    expect(await lock.unlockWithBiometrics('Unlock'), isFalse);
    expect(biometrics.asked, before);
  });

  test('turning it off needs the PIN and removes it', () async {
    await lock.setPin('482910');
    expect(await lock.disable('000000'), isA<WrongPin>());
    expect(lock.enabled, isTrue);
    expect(await lock.disable('482910'), isA<Unlocked>());
    expect(lock.enabled, isFalse);
    expect(await app.services.secrets.read(AppLock.pinKey), isNull);
  });

  test('a lock whose PIN the keychain lost turns itself off', () async {
    await lock.setPin('482910');
    await app.services.secrets.delete(AppLock.pinKey);
    final restarted = newLock();
    await restarted.start();
    expect(restarted.enabled, isFalse);
    expect(restarted.locked.value, isFalse);
    restarted.dispose();
  });

  test('"Forgot PIN" removes accounts, passwords, mail and the PIN', () async {
    final services = app.services;
    final account = services.store.accounts.all().single;
    await services.secrets.write(account.keychainKey, 'secret');
    await services.lock.setPin('482910');
    await services.deviceSync.start();
    final database = File('${app.directory.path}/mail.db');
    expect(database.existsSync(), isTrue);

    await services.resetEverything();
    expect(database.existsSync(), isFalse);
    expect(await services.secrets.read(account.keychainKey), isNull);
    expect(await services.secrets.read(AppLock.pinKey), isNull);
    expect(await services.secrets.read('database-key'), isNull);
    expect(await services.secrets.read('sync-code'), isNull);
  });

  test('PIN hashing for real uses the full strength', () {
    expect(
      AppLock(app.store, app.services.secrets).pinRounds,
      PinHasher.iterations,
    );
  });
}
