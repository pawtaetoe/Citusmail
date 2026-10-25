// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_web/mail_web.dart';

import 'secret_store.dart';

/// Optional link checks with Google Safe Browsing (off by default). When
/// on, Google's hash lists are kept up to date in a file next to the
/// database (public data, nothing about the user), and a link the user
/// opens is checked against them on the device first.
final class LinkSafety {
  LinkSafety(
    this._store,
    this._secrets,
    this._web, {
    this.listFile,
    this.builtInKey = const String.fromEnvironment(
      'CITUSMAIL_SAFE_BROWSING_KEY',
    ),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final MailStore _store;
  final SecretStore _secrets;
  final WebClient _web;

  /// Where the lists are kept; null keeps them in memory (tests).
  final File? listFile;

  /// This build's API key, if it has one; otherwise the user's own.
  final String builtInKey;
  final DateTime Function() _now;

  static const settingKey = 'app.safeBrowsing';
  static const statusKey = 'app.safeBrowsing.status';

  /// The user's own API key, in the keychain.
  static const keychainKey = 'safe-browsing-key';

  SafeBrowsingClient? _client;
  Future<void>? _updating;
  Timer? _timer;

  bool get enabled => _store.settings.read(settingKey) == 'on';

  /// Whether this build can check without the user's own key.
  bool get hasBuiltInKey => builtInKey.isNotEmpty;

  /// The last update's outcome, for Settings ("Lists updated...").
  String? get status => _store.settings.read(statusKey);

  /// Turns the checks on (with [ownKey] when the build has none) and
  /// downloads the lists. Returns a problem to show, or null.
  Future<String?> enable({String? ownKey}) async {
    final key = ownKey?.trim() ?? '';
    if (!hasBuiltInKey) {
      if (!RegExp(r'^[A-Za-z0-9_-]{20,100}$').hasMatch(key)) {
        return 'That doesn\'t look like a Google API key.';
      }
      await _secrets.write(keychainKey, key);
    }
    _client = null;
    _store.settings.write(settingKey, 'on');
    final problem = await updateIfDue(force: true);
    if (problem != null) {
      _store.settings.write(settingKey, 'off');
      return problem;
    }
    start();
    return null;
  }

  /// Turns the checks off and deletes the lists (the key stays, for
  /// turning them on again).
  Future<void> disable() async {
    _store.settings.write(settingKey, 'off');
    _store.settings.delete(statusKey);
    _timer?.cancel();
    _client = null;
    if (listFile case final file? when file.existsSync()) file.deleteSync();
  }

  /// Keeps the lists up to date while the app runs (Google says how often
  /// it may ask; this looks every 30 minutes).
  void start() {
    if (!enabled) return;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(updateIfDue()),
    );
    unawaited(updateIfDue());
  }

  void stop() => _timer?.cancel();

  /// Updates the lists when Google allows it. Returns a problem, or null.
  Future<String?> updateIfDue({bool force = false}) async {
    if (!enabled) return null;
    final running = _updating;
    if (running != null) {
      await running;
      return null;
    }
    final client = await _clientOrNull();
    if (client == null) return 'No Google API key is set.';
    if (!force && !client.updateDue) return null;
    String? problem;
    final run = () async {
      try {
        await client.update();
        await listFile?.writeAsBytes(client.database.encode(), flush: true);
        _store.settings.write(
          statusKey,
          'Lists updated ${_now().toUtc().toIso8601String()}',
        );
      } on WebException catch (e) {
        problem = 'Couldn\'t update Google\'s lists: ${e.message}';
        _store.settings.write(statusKey, problem!);
      } on FormatException {
        problem = 'Google\'s answer couldn\'t be read.';
        _store.settings.write(statusKey, problem!);
      }
    }();
    _updating = run;
    try {
      await run;
    } finally {
      _updating = null;
    }
    return problem;
  }

  /// What Google's lists say about [link]; null when the checks are off,
  /// the lists aren't there yet, or the confirmation couldn't be made in
  /// time (the link is then opened the usual way, with the usual
  /// warnings).
  Future<SafeBrowsingVerdict?> check(Uri link) async {
    if (!enabled) return null;
    final client = await _clientOrNull();
    if (client == null || client.database.isEmpty) return null;
    try {
      return await client
          .check(link.toString())
          .timeout(const Duration(seconds: 5));
    } on Object {
      return null;
    }
  }

  Future<SafeBrowsingClient?> _clientOrNull() async {
    if (_client case final client?) return client;
    final key = hasBuiltInKey ? builtInKey : await _secrets.read(keychainKey);
    if (key == null || key.isEmpty) return null;
    SafeBrowsingDatabase? database;
    if (listFile case final file? when file.existsSync()) {
      database = SafeBrowsingDatabase.decode(await file.readAsBytes());
    }
    return _client = SafeBrowsingClient(
      _web,
      key,
      database ?? SafeBrowsingDatabase(),
      now: _now,
    );
  }
}
