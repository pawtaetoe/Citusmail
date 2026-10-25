// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

/// The live test account's secrets in the system keychain (libsecret,
/// through `secret-tool`). Values go in on stdin and come back on stdout,
/// so they never appear in the process list or a file.
final class TestKeychain {
  const TestKeychain(this.service, this.account, {required this.label});

  /// The test account's password, stored with
  /// `secret-tool store --label="Fmail test account" service fmail-test account <email>`.
  const TestKeychain.password(String account)
    : this('fmail-test', account, label: 'Fmail test account');

  /// The test account's OAuth tokens, written by the live check itself.
  const TestKeychain.oauth(String account)
    : this('fmail-test-oauth', account, label: 'Fmail test account sign-in');

  final String service;
  final String account;
  final String label;

  /// The stored value, or null if there is none.
  Future<String?> read() async {
    final result = await _run([
      'lookup',
      'service',
      service,
      'account',
      account,
    ]);
    final value = (result.stdout as String).replaceAll(RegExp(r'\n$'), '');
    return result.exitCode != 0 || value.isEmpty ? null : value;
  }

  Future<void> write(String value) async {
    final Process process;
    try {
      process = await Process.start('secret-tool', [
        'store',
        '--label=$label',
        'service',
        service,
        'account',
        account,
      ]);
    } on ProcessException {
      throw StateError(_missing);
    }
    process.stdin.write(value);
    await process.stdin.close();
    final errors = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    if (await process.exitCode != 0) {
      throw StateError('the keychain did not store the value: $errors');
    }
  }

  Future<void> delete() async {
    await _run(['clear', 'service', service, 'account', account]);
  }

  static Future<ProcessResult> _run(List<String> arguments) async {
    try {
      return await Process.run('secret-tool', arguments);
    } on ProcessException {
      throw StateError(_missing);
    }
  }

  static const _missing = 'secret-tool not found (apt install libsecret-tools)';
}
