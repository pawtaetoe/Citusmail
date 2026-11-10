// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_appsync/mail_appsync.dart';

import 'frames.dart';
import 'pairing_crypto.dart';
import 'pairing_offer.dart';
import 'transfer.dart';
import 'x25519.dart';

/// The message types after the phone's first, plain message (its key).
abstract final class PairingMessage {
  static const hello = 1;
  static const welcome = 2;
  static const accounts = 3;
  static const results = 4;
  static const cancel = 5;

  static final magic = ascii.encode('CMPAIR');

  /// `CMPAIR | version | phone key`.
  static Uint8List first(List<int> phoneKey) =>
      Uint8List.fromList([...magic, PairingOffer.version, ...phoneKey]);

  /// The phone's key in [frame], or null if it isn't a first message.
  static Uint8List? phoneKeyIn(List<int> frame) {
    if (frame.length != magic.length + 1 + X25519.keyLength) return null;
    for (var i = 0; i < magic.length; i++) {
      if (frame[i] != magic[i]) return null;
    }
    if (frame[magic.length] != PairingOffer.version) return null;
    return Uint8List.fromList(frame.sublist(magic.length + 1));
  }
}

/// Adds the accounts on the computer and says how each went.
typedef AccountReceiver = Future<List<TransferResult>> Function(
  AccountTransfer transfer,
);

/// Where the computer's side of a pairing is.
sealed class PairingHostState {
  const PairingHostState();
}

/// Showing the QR code: waiting for the phone, or for a file from it.
final class HostWaiting extends PairingHostState {
  const HostWaiting({required this.listening});

  /// Whether the phone can still connect over the network (else only a
  /// file is accepted, until the code expires).
  final bool listening;
}

/// The phone connected and proved it scanned the code; the user chooses
/// accounts on it.
final class HostConnected extends PairingHostState {
  const HostConnected({required this.checkCode, required this.phoneName});

  final String checkCode;
  final String phoneName;
}

/// Adding the accounts.
final class HostReceiving extends PairingHostState {
  const HostReceiving(this.count);

  final int count;
}

/// Done: how each account went.
final class HostFinished extends PairingHostState {
  const HostFinished(this.results, {required this.fromFile});

  final List<TransferResult> results;
  final bool fromFile;
}

/// Why it ended without accounts.
enum HostProblem {
  /// The phone cancelled.
  cancelled,

  /// The connection to the phone was lost.
  connectionLost,

  /// Too many connections with a wrong key or token.
  tooManyTries,
}

final class HostFailed extends PairingHostState {
  const HostFailed(this.problem);

  final HostProblem problem;
}

/// The code expired; nothing was received.
final class HostExpired extends PairingHostState {
  const HostExpired();
}

/// The computer's side: a one-time listener on the local network, a
/// one-time key pair and token (in the QR code), and the file route. One
/// transfer only; afterwards (or after [fileWindow]) the private key is
/// wiped and nothing more is accepted.
final class PairingHost {
  PairingHost._({
    required this.computerName,
    required this.clients,
    required this._receive,
    required this._privateKey,
    required this.offer,
    required List<ServerSocket> servers,
    required this.networkUntil,
    required this.fileUntil,
    required this._answerTimeout,
    required this._handshakeTimeout,
  }) : _servers = servers,
       _state = HostWaiting(listening: servers.isNotEmpty);

  /// How long the phone has to connect.
  static const defaultNetworkWindow = Duration(minutes: 5);

  /// How long a file from the phone can be opened.
  static const defaultFileWindow = Duration(minutes: 15);

  /// Connections with a wrong key or token before the code is closed.
  static const maxFailedTries = 5;

  /// Starts listening on [addresses] (default: this computer's local
  /// network addresses) on a random port. With no address the code still
  /// works for the file route.
  static Future<PairingHost> start({
    required String computerName,
    required AccountReceiver receive,
    Map<String, String> clients = const {},
    List<InternetAddress>? addresses,
    Duration networkWindow = defaultNetworkWindow,
    Duration fileWindow = defaultFileWindow,
    Duration answerTimeout = const Duration(minutes: 10),
    Duration handshakeTimeout = const Duration(seconds: 15),
    Random? random,
    DateTime Function() now = DateTime.now,
  }) async {
    final r = random ?? Random.secure();
    final privateKey = X25519.newPrivateKey(r);
    final token = Uint8List.fromList([
      for (var i = 0; i < PairingOffer.tokenLength; i++) r.nextInt(256),
    ]);
    final candidates = (addresses ?? await LocalNetwork.ownAddresses())
        .where(LocalNetwork.isLocal)
        .toList();
    final servers = <ServerSocket>[];
    final bound = <InternetAddress>[];
    var port = 0;
    for (final address in candidates) {
      if (bound.length == PairingOffer.maxAddresses) break;
      try {
        final server = await ServerSocket.bind(address, port);
        port = server.port;
        servers.add(server);
        bound.add(address);
      } on SocketException {
        // Taken on this address, or the interface went away: skip it.
      }
    }
    final start = now();
    final host = PairingHost._(
      computerName: computerName,
      clients: clients,
      receive: receive,
      privateKey: privateKey,
      offer: PairingOffer(
        addresses: bound,
        port: port,
        publicKey: X25519.publicKey(privateKey),
        token: token,
      ),
      servers: servers,
      networkUntil: start.add(networkWindow),
      fileUntil: start.add(fileWindow),
      answerTimeout: answerTimeout,
      handshakeTimeout: handshakeTimeout,
    );
    host._listen(networkWindow, fileWindow);
    return host;
  }

  final String computerName;

  /// This build's OAuth client ids by provider: the phone sends tokens
  /// only for the clients the computer renews with.
  final Map<String, String> clients;
  final AccountReceiver _receive;
  final Uint8List _privateKey;
  final List<ServerSocket> _servers;
  final Duration _answerTimeout;
  final Duration _handshakeTimeout;

  /// What the QR code shows.
  final PairingOffer offer;

  /// Until when the phone can connect, and a file can be opened.
  final DateTime networkUntil;
  final DateTime fileUntil;

  Timer? _networkTimer;
  Timer? _fileTimer;
  int _failedTries = 0;
  bool _paired = false;
  bool _over = false;
  FrameChannel? _channel;

  PairingHostState _state;
  PairingHostState get state => _state;
  final _changes = StreamController<PairingHostState>.broadcast();

  /// Each change of [state].
  Stream<PairingHostState> get changes => _changes.stream;

  void _set(PairingHostState state) {
    _state = state;
    if (!_changes.isClosed) _changes.add(state);
  }

  void _listen(Duration networkWindow, Duration fileWindow) {
    for (final server in _servers) {
      server.listen(_handle, onError: (Object _) {});
    }
    _networkTimer = Timer(networkWindow, () {
      _stopListening();
      if (_state is HostWaiting) _set(const HostWaiting(listening: false));
    });
    _fileTimer = Timer(fileWindow, () {
      if (_state is HostWaiting) {
        _end(const HostExpired());
      }
    });
  }

  void _stopListening() {
    _networkTimer?.cancel();
    for (final server in _servers) {
      unawaited(server.close());
    }
    _servers.clear();
  }

  /// Wipes the key and stops everything; [state] becomes [last].
  void _end(PairingHostState last) {
    if (_over) return;
    _over = true;
    _stopListening();
    _fileTimer?.cancel();
    _privateKey.fillRange(0, _privateKey.length, 0);
    _set(last);
    unawaited(_changes.close());
  }

  /// Whether nothing more will be accepted.
  bool get isOver => _over;

  Future<void> _handle(Socket socket) async {
    if (_paired || _over || !LocalNetwork.isLocal(socket.remoteAddress)) {
      socket.destroy();
      return;
    }
    final channel = FrameChannel(socket);
    final SealedDirection toPhone;
    final SealedDirection fromPhone;
    final String phoneName;
    try {
      final phoneKey = PairingMessage.phoneKeyIn(
        await channel.next(_handshakeTimeout),
      );
      if (phoneKey == null) throw const PairingFormatException('not a phone');
      final keys = PairingKeys.derive(
        sharedSecret: X25519.sharedSecret(_privateKey, phoneKey),
        token: offer.token,
        computerKey: offer.publicKey,
        phoneKey: phoneKey,
      );
      fromPhone = SealedDirection(keys.toComputer);
      toPhone = SealedDirection(keys.toPhone);
      final hello = fromPhone.open(
        PairingMessage.hello,
        await channel.next(_handshakeTimeout),
      );
      phoneName = hello is Map && hello['device'] is String
          ? _short(hello['device'] as String)
          : 'your phone';
      if (_paired || _over) throw const PairingFormatException('taken');
      _paired = true;
      _stopListening();
      channel.send(
        toPhone.seal(PairingMessage.welcome, {
          'device': computerName,
          'clients': clients,
        }),
      );
      _channel = channel;
      _set(HostConnected(checkCode: keys.checkCode, phoneName: phoneName));
    } on Object catch (e) {
      await channel.close();
      if (e is AuthenticationFailed || e is ArgumentError) {
        // A wrong key or token: someone without the code, or an old one.
        if (++_failedTries >= maxFailedTries) {
          _end(const HostFailed(HostProblem.tooManyTries));
        }
      }
      return;
    }
    try {
      final frame = await channel.next(_answerTimeout);
      if (frame.isNotEmpty && frame[0] == PairingMessage.cancel) {
        fromPhone.open(PairingMessage.cancel, frame);
        await channel.close();
        _end(const HostFailed(HostProblem.cancelled));
        return;
      }
      final transfer = AccountTransfer.fromJson(
        fromPhone.open(PairingMessage.accounts, frame),
      );
      _set(HostReceiving(transfer.accounts.length));
      final results = await _receive(transfer);
      channel.send(
        toPhone.seal(PairingMessage.results, [
          for (final r in results) r.toJson(),
        ]),
      );
      await channel.close();
      _end(HostFinished(results, fromFile: false));
    } on Object {
      await channel.close();
      _end(const HostFailed(HostProblem.connectionLost));
    }
  }

  /// Opens a file the phone made for this code and adds its accounts.
  /// Throws [PairingFileException]; a file for another code or a damaged
  /// one leaves the code open for another try.
  Future<List<TransferResult>> openFile(List<int> file) async {
    if (_over || _paired || _state is! HostWaiting) {
      throw const PairingFileException(PairingFileProblem.expired);
    }
    final transfer = PairingFile.open(
      file,
      privateKey: _privateKey,
      token: offer.token,
    );
    _paired = true;
    _stopListening();
    _set(HostReceiving(transfer.accounts.length));
    final results = await _receive(transfer);
    _end(HostFinished(results, fromFile: true));
    return results;
  }

  /// Stops listening and forgets the key (the page was closed).
  Future<void> close() async {
    await _channel?.close();
    if (!_over) _end(const HostExpired());
  }

  static String _short(String name) {
    final clean = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    if (clean.isEmpty) return 'your phone';
    return clean.length > 60 ? clean.substring(0, 60) : clean;
  }
}
