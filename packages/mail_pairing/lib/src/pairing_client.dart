// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:mail_appsync/mail_appsync.dart';

import 'frames.dart';
import 'pairing_crypto.dart';
import 'pairing_host.dart';
import 'pairing_offer.dart';
import 'transfer.dart';
import 'x25519.dart';

/// What went wrong on the phone's side.
enum PairingProblem {
  /// None of the computer's addresses answered: another network, or the
  /// network keeps devices apart.
  unreachable,

  /// The computer closed the connection: the code was used, expired, or
  /// isn't the one it shows.
  refused,

  /// Something answered that isn't the computer of the code (or the
  /// connection was tampered with).
  notThatComputer,

  /// The connection broke, or the computer took too long.
  connectionLost,
}

final class PairingException implements Exception {
  const PairingException(this.problem);

  final PairingProblem problem;

  @override
  String toString() => 'PairingException(${problem.name})';
}

/// The phone's side: connects to the computer of a scanned code.
abstract final class PairingClient {
  /// Connects to the computer of [offer] and proves the code was
  /// scanned. Throws [PairingException].
  static Future<PairingConnection> connect(
    PairingOffer offer, {
    required String phoneName,
    Duration connectTimeout = const Duration(seconds: 4),
    Duration answerTimeout = const Duration(seconds: 15),
    Random? random,
  }) async {
    // Closed by the FrameChannel it goes into.
    // ignore: close_sinks
    Socket? socket;
    for (final address in offer.addresses) {
      if (!LocalNetwork.isLocal(address)) continue;
      try {
        socket = await Socket.connect(
          address,
          offer.port,
          timeout: connectTimeout,
        );
        break;
      } on SocketException {
        // Try the next address.
      } on TimeoutException {
        // Try the next address.
      }
    }
    if (socket == null) {
      throw const PairingException(PairingProblem.unreachable);
    }
    final channel = FrameChannel(socket);
    try {
      final r = random ?? Random.secure();
      final privateKey = X25519.newPrivateKey(r);
      final phoneKey = X25519.publicKey(privateKey);
      final keys = PairingKeys.derive(
        sharedSecret: X25519.sharedSecret(privateKey, offer.publicKey),
        token: offer.token,
        computerKey: offer.publicKey,
        phoneKey: phoneKey,
      );
      privateKey.fillRange(0, privateKey.length, 0);
      final toComputer = SealedDirection(keys.toComputer);
      final fromComputer = SealedDirection(keys.toPhone);
      channel
        ..send(PairingMessage.first(phoneKey))
        ..send(toComputer.seal(PairingMessage.hello, {'device': phoneName}));
      final Object? welcome;
      try {
        welcome = fromComputer.open(
          PairingMessage.welcome,
          await channel.next(answerTimeout),
        );
      } on PairingFormatException {
        throw const PairingException(PairingProblem.refused);
      } on TimeoutException {
        throw const PairingException(PairingProblem.connectionLost);
      } on AuthenticationFailed {
        throw const PairingException(PairingProblem.notThatComputer);
      }
      if (welcome is! Map || welcome['device'] is! String) {
        throw const PairingException(PairingProblem.notThatComputer);
      }
      final clients = welcome['clients'];
      return PairingConnection._(
        channel,
        toComputer,
        fromComputer,
        computerName: welcome['device'] as String,
        checkCode: keys.checkCode,
        clients: {
          if (clients is Map)
            for (final e in clients.entries)
              if (e.value is String) '${e.key}': e.value as String,
        },
      );
    } on Object {
      await channel.close();
      rethrow;
    }
  }
}

/// A connection to the computer, ready for the accounts.
final class PairingConnection {
  PairingConnection._(
    this._channel,
    this._toComputer,
    this._fromComputer, {
    required this.computerName,
    required this.checkCode,
    required this.clients,
  });

  final FrameChannel _channel;
  final SealedDirection _toComputer;
  final SealedDirection _fromComputer;

  /// The computer's name, as it says.
  final String computerName;

  /// The same six digits the computer shows.
  final String checkCode;

  /// The computer's OAuth client ids by provider.
  final Map<String, String> clients;

  bool _done = false;

  /// Sends the accounts and waits for how each went on the computer.
  /// Throws [PairingException] (connectionLost).
  Future<List<TransferResult>> send(
    AccountTransfer transfer, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_done) throw StateError('already sent');
    _done = true;
    try {
      _channel.send(
        _toComputer.seal(PairingMessage.accounts, transfer.toJson()),
      );
      final answer = _fromComputer.open(
        PairingMessage.results,
        await _channel.next(timeout),
      );
      if (answer is! List) throw const PairingFormatException('bad results');
      return [for (final r in answer) TransferResult.fromJson(r)];
    } on PairingFormatException {
      throw const PairingException(PairingProblem.connectionLost);
    } on AuthenticationFailed {
      throw const PairingException(PairingProblem.connectionLost);
    } on TimeoutException {
      throw const PairingException(PairingProblem.connectionLost);
    } finally {
      await _channel.close();
    }
  }

  /// Tells the computer nothing is coming, and closes.
  Future<void> cancel() async {
    if (_done) return;
    _done = true;
    _channel.send(_toComputer.seal(PairingMessage.cancel, null));
    await _channel.close();
  }
}
