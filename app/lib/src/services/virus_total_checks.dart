// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_lookup/mail_lookup.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_web/mail_web.dart';

import 'secret_store.dart';

/// Optional VirusTotal lookups with the user's own API key (off by
/// default). Offered only for what the on-device checks flagged (a risky
/// attachment, a suspicious link), and only when the user asks for one.
final class VirusTotalChecks {
  VirusTotalChecks(this._store, this._secrets, this._web);

  final MailStore _store;
  final SecretStore _secrets;
  final WebClient _web;

  static const settingKey = 'app.virusTotal';
  static const keychainKey = 'virustotal-key';

  /// SHA-256 of an empty file: looked up once to check a new key (it
  /// costs one lookup of the key's quota and tells VirusTotal nothing).
  static const _probe =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  bool get enabled => _store.settings.read(settingKey) == 'on';

  /// Checks [key] with one lookup and turns the checks on. Returns a
  /// problem to show, or null.
  Future<String?> enable(String key) async {
    final trimmed = key.trim();
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(trimmed)) {
      return 'A VirusTotal API key is 64 letters and digits (0-9, a-f).';
    }
    try {
      await _client(trimmed).fileByHash(_probe);
    } on VirusTotalException catch (e) {
      return switch (e.problem) {
        VirusTotalProblem.badKey => 'VirusTotal didn\'t accept this key.',
        VirusTotalProblem.quota =>
          'This key\'s quota is used up for now. Try again later.',
        VirusTotalProblem.unavailable =>
          'Couldn\'t reach VirusTotal: ${e.message}',
      };
    }
    await _secrets.write(keychainKey, trimmed);
    _store.settings.write(settingKey, 'on');
    return null;
  }

  /// Turns the checks off and forgets the key.
  Future<void> disable() async {
    _store.settings.write(settingKey, 'off');
    await _secrets.delete(keychainKey);
  }

  /// A file, by its SHA-256 (never uploaded). Throws [VirusTotalException].
  Future<VirusTotalReport> file(List<int> bytes) async =>
      (await _stored()).file(bytes);

  /// A link (sends the address). Throws [VirusTotalException].
  Future<VirusTotalReport> link(Uri link) async => (await _stored()).url(link);

  Future<VirusTotalClient> _stored() async {
    final key = await _secrets.read(keychainKey);
    if (!enabled || key == null) {
      throw const VirusTotalException(
        VirusTotalProblem.badKey,
        'VirusTotal checks are off',
      );
    }
    return _client(key);
  }

  VirusTotalClient _client(String key) => VirusTotalClient(_web, key);
}
