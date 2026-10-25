// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'sender_blocker.dart';

/// Writes the user's blocked senders and folder rules as a Sieve script
/// (RFC 5228), so the mail server sorts mail as it arrives, even while no
/// device runs the app.
///
/// The same order as on the device: blocks first (addresses, then
/// domains), then folder rules, oldest first; the first match files the
/// message and stops.
abstract final class SieveRules {
  /// The script, or null when there is nothing to run. [extensions] are
  /// the server's Sieve extensions; [blockTarget] is where blocked mail
  /// goes (Junk, or Trash); [folders] names each rule's folder.
  static String? script({
    required List<BlockedSender> blocks,
    required StoredMailbox? blockTarget,
    required List<FolderRule> rules,
    required Map<int, StoredMailbox> folders,
    required Set<String> extensions,
  }) {
    final unicode = extensions.contains('comparator-i;unicode-casemap');
    final tests = <(String, String)>[];
    if (blockTarget != null && blockTarget.selectable) {
      final sorted = [...blocks]
        ..sort((a, b) => a.kind.index.compareTo(b.kind.index));
      for (final b in sorted) {
        tests.add((
          switch (b.kind) {
            BlockKind.address => _address('"from"', b.value),
            BlockKind.domain => _domain(b.value),
          },
          blockTarget.name,
        ));
      }
    }
    var subjects = false;
    for (final rule in rules) {
      final folder = folders[rule.mailboxId];
      if (folder == null || !folder.selectable || folder.isInbox) continue;
      final test = switch (rule.field) {
        RuleField.fromAddress => _address('"from"', rule.value),
        RuleField.fromDomain => _domain(rule.value),
        RuleField.toAddress => _address('["to", "cc"]', rule.value),
        RuleField.subject =>
          'header :contains${unicode ? ' :comparator "i;unicode-casemap"' : ''} '
              '"subject" ${_string(rule.value)}',
      };
      subjects |= rule.field == RuleField.subject;
      tests.add((test, folder.name));
    }
    if (tests.isEmpty) return null;

    final out = StringBuffer()
      ..write(
        '# Citusmail: your blocked senders and folder rules, kept up to date\r\n'
        '# by the app. Changes made here are replaced.\r\n',
      )
      ..write(
        unicode && subjects
            ? 'require ["fileinto", "comparator-i;unicode-casemap"];\r\n'
            : 'require "fileinto";\r\n',
      );
    for (final (test, folder) in tests) {
      out.write(
        'if $test {\r\n  fileinto ${_string(folder)};\r\n  stop;\r\n}\r\n',
      );
    }
    return out.toString();
  }

  /// Address tests compare case-insensitively (i;ascii-casemap, the
  /// default), as the app does for addresses.
  static String _address(String headers, String value) =>
      'address :is $headers ${_string(value)}';

  /// The domain, or any of its subdomains.
  static String _domain(String domain) =>
      'anyof (address :domain :is "from" ${_string(domain)}, '
      'address :domain :matches "from" ${_string('*.${_wildcards(domain)}')})';

  /// A quoted string: backslash and quote escaped, line breaks and other
  /// control characters made spaces, so a value can never end the string.
  static String _string(String value) {
    final clean = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
    return '"${clean.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  /// `*` and `?` are literal in a :matches pattern when escaped. (The
  /// backslash added here is escaped again by [_string].)
  static String _wildcards(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('*', r'\*')
      .replaceAll('?', r'\?');
}

/// Where the server rules of an account stand.
enum ServerRulesState {
  /// The script is on the server and active.
  active,

  /// Nothing to run (no blocks or folder rules); no script is left.
  nothingToRun,

  /// The server runs another script (the user's own, or another app's);
  /// it is left alone and the rules run on the device only.
  otherScriptActive,

  /// The server offers no ManageSieve (checked again after a day).
  notSupported,

  /// The last attempt failed; it is tried again with the next sync.
  failed,
}

final class ServerRulesStatus {
  const ServerRulesStatus(this.state, this.at, {this.detail, this.digest});

  final ServerRulesState state;
  final DateTime at;

  /// The other script's name, or what failed.
  final String? detail;

  /// SHA-256 of the script last stored, to skip unchanged uploads.
  final String? digest;

  String toJson() => jsonEncode({
    'state': state.name,
    'at': at.toUtc().millisecondsSinceEpoch,
    'detail': ?detail,
    'digest': ?digest,
  });

  static ServerRulesStatus? fromJson(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['at'] is! int) return null;
      final state = ServerRulesState.values.asNameMap()[json['state']];
      if (state == null) return null;
      return ServerRulesStatus(
        state,
        DateTime.fromMillisecondsSinceEpoch(json['at'] as int, isUtc: true),
        detail: json['detail'] is String ? json['detail'] as String : null,
        digest: json['digest'] is String ? json['digest'] as String : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Opens a logged-in ManageSieve connection for an account.
typedef SieveOpener = Future<ManageSieveClient> Function(Account account);

/// Keeps the server's copy of the rules up to date, when the user turned
/// it on: one script named [scriptName], stored and activated only if the
/// server runs no other script. Turning it off removes the script.
///
/// Runs after each sync, but connects only when something changed, once a
/// day to check, or an hour after a failure. Its problems never fail the
/// sync.
final class ServerRules {
  ServerRules(this._store, this._open, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final MailStore _store;
  final SieveOpener _open;
  final DateTime Function() _now;

  /// The setting that turns it on (`on`); shared with the app.
  static const settingKey = 'mail.serverRules';

  /// The script's name on the server.
  static const scriptName = 'citusmail';

  static const recheck = Duration(days: 1);
  static const retryFailed = Duration(hours: 1);

  static String _statusKey(int accountId) => 'serverRules.$accountId';

  bool get enabled => _store.settings.read(settingKey) == 'on';

  /// The account's last known state, or null if never checked (or off).
  ServerRulesStatus? status(int accountId) => statusOf(_store, accountId);

  /// The same, read by the app.
  static ServerRulesStatus? statusOf(MailStore store, int accountId) =>
      ServerRulesStatus.fromJson(store.settings.read(_statusKey(accountId)));

  /// Brings the server in line; returns the new state (null when off).
  Future<ServerRulesStatus?> run(Account account) async {
    final previous = status(account.id);
    final now = _now().toUtc();
    final fresh = previous != null && now.difference(previous.at) < recheck;
    if (!enabled) {
      if (previous == null) return null;
      if (previous.state == ServerRulesState.notSupported ||
          previous.state == ServerRulesState.otherScriptActive) {
        _store.settings.delete(_statusKey(account.id));
        return null;
      }
      // Ours may be on the server: take it away.
      final removed = await _session(account, (client) async {
        await _remove(client);
        return null;
      });
      if (removed.state != ServerRulesState.failed) {
        _store.settings.delete(_statusKey(account.id));
        return null;
      }
      return _save(account, removed);
    }
    if (fresh &&
        (previous.state == ServerRulesState.notSupported ||
            previous.state == ServerRulesState.otherScriptActive)) {
      return previous;
    }
    if (previous?.state == ServerRulesState.failed &&
        now.difference(previous!.at) < retryFailed) {
      return previous;
    }
    // Skip the connection when the script would be the same.
    final expected = _script(account, _assumedExtensions(previous));
    if (fresh &&
        (previous.state == ServerRulesState.active ||
            previous.state == ServerRulesState.nothingToRun) &&
        previous.digest == _digest(expected)) {
      return previous;
    }
    final result = await _session(account, (client) async {
      final script = _script(account, client.capabilities.extensions);
      final scripts = await client.listScripts();
      final ours = scripts.where((s) => s.name == scriptName).firstOrNull;
      final other = scripts
          .where((s) => s.active && s.name != scriptName)
          .firstOrNull;
      if (script == null) {
        await _remove(client, existing: ours);
        return ServerRulesStatus(
          ServerRulesState.nothingToRun,
          now,
          digest: _digest(null),
          detail: _extensionsNote(client),
        );
      }
      if (other != null) {
        return ServerRulesStatus(
          ServerRulesState.otherScriptActive,
          now,
          detail: other.name,
        );
      }
      await client.putScript(scriptName, script);
      if (ours?.active != true) await client.setActive(scriptName);
      return ServerRulesStatus(
        ServerRulesState.active,
        now,
        digest: _digest(script),
        detail: _extensionsNote(client),
      );
    });
    return _save(account, result);
  }

  /// Opens a session, runs [action], logs out. Connection problems on the
  /// ManageSieve port mean the server doesn't offer it (the mail sync
  /// just reached the same server).
  Future<ServerRulesStatus> _session(
    Account account,
    Future<ServerRulesStatus?> Function(ManageSieveClient client) action,
  ) async {
    final now = _now().toUtc();
    final ManageSieveClient client;
    try {
      client = await _open(account);
    } on MailConnectionException {
      return ServerRulesStatus(ServerRulesState.notSupported, now);
    } on MailTimeoutException {
      return ServerRulesStatus(ServerRulesState.notSupported, now);
    } on MailException catch (e) {
      return ServerRulesStatus(ServerRulesState.failed, now, detail: e.message);
    }
    try {
      return await action(client) ??
          ServerRulesStatus(ServerRulesState.nothingToRun, now);
    } on MailException catch (e) {
      return ServerRulesStatus(ServerRulesState.failed, now, detail: e.message);
    } finally {
      await client.logout();
    }
  }

  /// Deactivates and deletes our script, if it is there.
  static Future<void> _remove(
    ManageSieveClient client, {
    SieveScriptInfo? existing,
  }) async {
    final ours =
        existing ??
        (await client.listScripts())
            .where((s) => s.name == scriptName)
            .firstOrNull;
    if (ours == null) return;
    if (ours.active) await client.setActive(null);
    await client.deleteScript(scriptName);
  }

  ServerRulesStatus _save(Account account, ServerRulesStatus status) {
    _store.settings.write(_statusKey(account.id), status.toJson());
    return status;
  }

  String? _script(Account account, Set<String> extensions) {
    final rules = _store.folderRules.forAccount(account.id);
    return SieveRules.script(
      blocks: _store.blocks.all(),
      blockTarget: SenderBlocker.destination(_store, account.id),
      rules: rules,
      folders: {
        for (final r in rules) r.mailboxId: ?_store.mailboxes.byId(r.mailboxId),
      },
      extensions: extensions,
    );
  }

  /// What the script depended on last time (the comparator).
  static Set<String> _assumedExtensions(ServerRulesStatus? previous) =>
      previous?.detail == _unicodeNote
      ? const {'comparator-i;unicode-casemap'}
      : const {};

  static const _unicodeNote = 'unicode-casemap';

  static String? _extensionsNote(ManageSieveClient client) =>
      client.capabilities.extensions.contains('comparator-i;unicode-casemap')
      ? _unicodeNote
      : null;

  static String _digest(String? script) =>
      sha256.convert(utf8.encode(script ?? '')).toString();
}
