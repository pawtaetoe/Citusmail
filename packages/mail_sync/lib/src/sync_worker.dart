// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:isolate';

import 'package:mail_store/mail_store.dart';

import 'account_synchronizer.dart';
import 'connector.dart';
import 'message_loader.dart';
import 'sync_engine.dart';

/// Builds the connector inside the worker. Must be a top-level or static
/// function, or a closure over plain data, so it can be sent to it.
typedef ConnectorFactory = MailConnector Function(
  CredentialProvider credentials,
);

MailConnector _defaultConnector(CredentialProvider credentials) =>
    DefaultMailConnector(credentials);

/// What the worker needs to start.
final class SyncWorkerConfig {
  const SyncWorkerConfig({
    required this.databasePath,
    required this.key,
    this.connector = _defaultConnector,
    this.fullSyncInterval = const Duration(minutes: 15),
  });

  final String databasePath;
  final DatabaseKey key;
  final ConnectorFactory connector;
  final Duration fullSyncInterval;
}

/// A request the worker could not complete.
final class SyncWorkerException implements Exception {
  const SyncWorkerException(this.failure);

  final SyncFailure failure;

  @override
  String toString() =>
      'SyncWorkerException(${failure.kind.name}: ${failure.message})';
}

/// Runs the [SyncEngine] in a background isolate, so syncing never makes
/// the UI stutter. The worker opens its own connection to the encrypted
/// database; the UI reads what it writes.
///
/// Passwords stay with the caller: the worker asks for one through
/// [CredentialProvider] each time it logs in, so the keychain is only
/// used from the UI isolate.
final class SyncWorker {
  SyncWorker._(this._config, this._credentials);

  /// Starts the worker.
  static Future<SyncWorker> spawn(
    SyncWorkerConfig config, {
    required CredentialProvider credentials,
  }) async {
    final worker = SyncWorker._(config, credentials);
    await worker._spawn();
    return worker;
  }

  final SyncWorkerConfig _config;
  final CredentialProvider _credentials;
  // Delivered as they arrive, so an event always reaches listeners before
  // the reply to the request that caused it.
  final _events = StreamController<SyncEvent>.broadcast(sync: true);
  final _pending = <int, Completer<Object?>>{};
  final _restarts = <DateTime>[];
  int _nextId = 0;
  bool _started = false;
  bool _closed = false;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _inbox;
  Future<void>? _respawning;

  /// Sync progress and failures, as from [SyncEngine.events].
  Stream<SyncEvent> get events => _events.stream;

  /// Starts syncing every account (and watching their inboxes).
  Future<void> start() async {
    _started = true;
    await _request(const _Start());
  }

  /// Stops syncing; waits for running syncs to finish.
  Future<void> stop() async {
    _started = false;
    await _request(const _Stop());
  }

  /// Syncs one account now, or all.
  Future<void> syncNow([int? accountId]) => _request(_SyncNow(accountId));

  /// Asks for a sync soon (after a local change).
  void requestSync(int accountId) => unawaited(
    _request(_RequestSync(accountId)).catchError((Object _) => null),
  );

  /// Syncs the account at [at] (a delayed send becomes due then).
  void syncAt(int accountId, DateTime at) => unawaited(
    _request(_SyncAt(accountId, at)).catchError((Object _) => null),
  );

  /// Downloads a message body into the store. Throws
  /// [BodyUnavailableException] or [SyncWorkerException].
  Future<void> loadBody(int messageId) => _request(_LoadBody(messageId));

  /// Loads older mail of a folder; returns how many messages were added.
  Future<int> fetchOlder(int mailboxId, {int count = 100}) async =>
      await _request(_FetchOlder(mailboxId, count)) as int;

  /// Creates a folder on the server; returns its id. Throws
  /// [SyncWorkerException] (offline, refused) or [ArgumentError] (a name
  /// that cannot be a folder).
  Future<int> createFolder(int accountId, String name) async =>
      await _request(_CreateFolder(accountId, name)) as int;

  /// After accounts were added, removed or changed.
  Future<void> accountsChanged() => _request(const _AccountsChanged());

  /// Stops the worker for good.
  Future<void> close() async {
    if (_closed) return;
    await _request(const _Shutdown()).catchError((Object _) => null);
    _closed = true;
    _teardown();
    _failPending('closed');
    await _events.close();
  }

  // --------------------------------------------------------------- spawning

  Future<void> _spawn() async {
    final inbox = _inbox = ReceivePort();
    final ready = Completer<SendPort>();
    inbox.listen((message) => _receive(message, ready));
    _isolate = await Isolate.spawn(
      _workerMain,
      _Boot(_config, inbox.sendPort),
      debugName: 'sync worker',
      onExit: inbox.sendPort,
      onError: inbox.sendPort,
      errorsAreFatal: true,
    );
    _commands = await ready.future;
  }

  void _receive(Object? message, Completer<SendPort> ready) {
    switch (message) {
      case _Ready(:final commands):
        if (!ready.isCompleted) ready.complete(commands);
      case _Reply(:final id, :final value):
        _pending.remove(id)?.complete(value);
      case _Failed(:final id, :final error):
        _pending.remove(id)?.completeError(error);
      case _Event(:final event):
        _events.add(event);
      case _PasswordRequest(:final id, :final account):
        unawaited(_answerPassword(id, account));
      case null || List<Object?>():
        // Exit (null) or an uncaught error ([error, stack]) in the worker.
        if (!ready.isCompleted) {
          ready.completeError(
            const SyncWorkerException(
              SyncFailure(
                SyncFailureKind.server,
                'the sync worker could not start',
              ),
            ),
          );
        }
        _workerDied();
    }
  }

  Future<void> _answerPassword(int id, Account account) async {
    try {
      final password = await _credentials.passwordFor(account);
      _commands?.send(_PasswordReply(id, password, null));
    } on Object catch (e) {
      _commands?.send(_PasswordReply(id, null, SyncFailure.from(e)));
    }
  }

  /// The worker stopped unexpectedly: fail what was waiting and start a
  /// new one (at most three times in ten minutes, to avoid a crash loop).
  void _workerDied() {
    if (_closed) return;
    _teardown();
    _failPending('the sync worker stopped');
    final now = DateTime.now();
    _restarts.removeWhere(
      (t) => now.difference(t) > const Duration(minutes: 10),
    );
    if (_restarts.length >= 3) {
      _events.close();
      _closed = true;
      return;
    }
    _restarts.add(now);
    _respawning = _spawn()
        .then((_) async {
          if (_started) await _send(const _Start());
        })
        .catchError((Object _) => _workerDied());
  }

  void _teardown() {
    _inbox?.close();
    _inbox = null;
    _commands = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  void _failPending(String reason) {
    final waiting = [..._pending.values];
    _pending.clear();
    for (final completer in waiting) {
      completer.completeError(
        SyncWorkerException(SyncFailure(SyncFailureKind.server, reason)),
      );
    }
  }

  Future<Object?> _request(_Command command) async {
    if (_respawning case final respawning?) {
      await respawning;
      _respawning = null;
    }
    return _send(command);
  }

  Future<Object?> _send(_Command command) {
    final commands = _commands;
    if (_closed || commands == null) {
      return Future.error(
        const SyncWorkerException(
          SyncFailure(SyncFailureKind.server, 'the sync worker is not running'),
        ),
      );
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    commands.send(_Request(id, command));
    return completer.future;
  }
}

// ------------------------------------------------------------- the worker

Future<void> _workerMain(_Boot boot) async {
  final commands = ReceivePort();
  final reply = boot.replyTo;
  final credentials = _RemoteCredentials(reply);
  final store = MailStore.open(boot.config.databasePath, boot.config.key);
  final engine = SyncEngine(
    store,
    boot.config.connector(credentials),
    fullSyncInterval: boot.config.fullSyncInterval,
  );
  final events = engine.events.listen((e) => reply.send(_Event(e)));
  var running = false;

  Future<Object?> handle(_Command command) async {
    switch (command) {
      case _Start():
        running = true;
        engine.start();
      case _Stop():
        running = false;
        await engine.stop();
      case _SyncNow(:final accountId):
        final ids = accountId == null
            ? [for (final a in store.accounts.all()) a.id]
            : [accountId];
        await Future.wait([for (final id in ids) engine.syncAccount(id)]);
      case _RequestSync(:final accountId):
        engine.requestSync(accountId);
      case _SyncAt(:final accountId, :final at):
        engine.syncAt(accountId, at);
      case _LoadBody(:final messageId):
        await engine.loadBody(messageId);
      case _FetchOlder(:final mailboxId, :final count):
        return engine.fetchOlder(mailboxId, count: count);
      case _CreateFolder(:final accountId, :final name):
        return engine.createFolder(accountId, name);
      case _AccountsChanged():
        for (final account in store.accounts.all()) {
          await engine.accountChanged(account.id);
        }
        if (running) {
          await engine.stop();
          engine.start();
        }
      case _Shutdown():
        break;
    }
    return null;
  }

  reply.send(_Ready(commands.sendPort));
  await for (final message in commands) {
    switch (message) {
      case _PasswordReply():
        credentials.answer(message);
      case _Request(:final id, command: _Shutdown()):
        await events.cancel();
        await engine.dispose();
        store.close();
        reply.send(_Reply(id, null));
        commands.close();
      case _Request(:final id, :final command):
        unawaited(
          handle(command).then(
            (value) => reply.send(_Reply(id, value)),
            onError: (Object e) => reply.send(_Failed(id, _sendable(e))),
          ),
        );
    }
  }
}

/// Errors cross the isolate boundary as plain values.
Object _sendable(Object error) => switch (error) {
  BodyUnavailableException() => error,
  ArgumentError(:final message) => ArgumentError(message?.toString()),
  _ => SyncWorkerException(SyncFailure.from(error)),
};

/// Asks the UI isolate for passwords.
final class _RemoteCredentials implements CredentialProvider {
  _RemoteCredentials(this._reply);

  final SendPort _reply;
  final _waiting = <int, Completer<String>>{};
  int _nextId = 0;

  @override
  Future<String> passwordFor(Account account) {
    final id = _nextId++;
    final completer = _waiting[id] = Completer<String>();
    _reply.send(_PasswordRequest(id, account));
    return completer.future;
  }

  void answer(_PasswordReply reply) {
    final completer = _waiting.remove(reply.id);
    if (completer == null) return;
    if (reply.password case final password?) {
      completer.complete(password);
    } else {
      completer.completeError(
        SyncWorkerException(
          reply.failure ??
              const SyncFailure(SyncFailureKind.authentication, 'no password'),
        ),
      );
    }
  }
}

// ---------------------------------------------------------------- messages

final class _Boot {
  const _Boot(this.config, this.replyTo);

  final SyncWorkerConfig config;
  final SendPort replyTo;
}

final class _Ready {
  const _Ready(this.commands);

  final SendPort commands;
}

final class _Request {
  const _Request(this.id, this.command);

  final int id;
  final _Command command;
}

final class _Reply {
  const _Reply(this.id, this.value);

  final int id;
  final Object? value;
}

final class _Failed {
  const _Failed(this.id, this.error);

  final int id;
  final Object error;
}

final class _Event {
  const _Event(this.event);

  final SyncEvent event;
}

final class _PasswordRequest {
  const _PasswordRequest(this.id, this.account);

  final int id;
  final Account account;
}

final class _PasswordReply {
  const _PasswordReply(this.id, this.password, this.failure);

  final int id;
  final String? password;
  final SyncFailure? failure;
}

sealed class _Command {
  const _Command();
}

final class _Start extends _Command {
  const _Start();
}

final class _Stop extends _Command {
  const _Stop();
}

final class _SyncNow extends _Command {
  const _SyncNow(this.accountId);

  final int? accountId;
}

final class _RequestSync extends _Command {
  const _RequestSync(this.accountId);

  final int accountId;
}

final class _SyncAt extends _Command {
  const _SyncAt(this.accountId, this.at);

  final int accountId;
  final DateTime at;
}

final class _LoadBody extends _Command {
  const _LoadBody(this.messageId);

  final int messageId;
}

final class _FetchOlder extends _Command {
  const _FetchOlder(this.mailboxId, this.count);

  final int mailboxId;
  final int count;
}

final class _CreateFolder extends _Command {
  const _CreateFolder(this.accountId, this.name);

  final int accountId;
  final String name;
}

final class _AccountsChanged extends _Command {
  const _AccountsChanged();
}

final class _Shutdown extends _Command {
  const _Shutdown();
}
