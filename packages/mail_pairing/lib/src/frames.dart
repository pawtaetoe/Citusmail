// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'transfer.dart';

/// Messages on a socket, each with a 4-byte length in front (big endian),
/// at most [maxLength] bytes.
final class FrameChannel {
  FrameChannel(this.socket) {
    _subscription = socket.listen(
      _onData,
      onError: (Object _) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
  }

  static const maxLength = 1 << 20;

  final Socket socket;
  late final StreamSubscription<Uint8List> _subscription;
  final _buffer = BytesBuilder(copy: true);
  final _frames = <Uint8List>[];
  Completer<Uint8List?>? _waiting;
  bool _closed = false;
  bool _tooLong = false;

  void _onData(Uint8List data) {
    _buffer.add(data);
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < 4) return;
      final length =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      if (length > maxLength) {
        _tooLong = true;
        _finish();
        socket.destroy();
        return;
      }
      if (bytes.length < 4 + length) return;
      _buffer.clear();
      _buffer.add(bytes.sublist(4 + length));
      _deliver(Uint8List.sublistView(bytes, 4, 4 + length));
    }
  }

  void _deliver(Uint8List frame) {
    final waiting = _waiting;
    if (waiting != null && !waiting.isCompleted) {
      _waiting = null;
      waiting.complete(frame);
    } else {
      _frames.add(frame);
    }
  }

  void _finish() {
    _closed = true;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(null);
  }

  /// The next message. Throws [TimeoutException], or
  /// [PairingFormatException] when the other side closed (or sent too
  /// much).
  Future<Uint8List> next(Duration timeout) async {
    if (_frames.isNotEmpty) return _frames.removeAt(0);
    if (_closed) throw _closedError();
    final waiting = _waiting = Completer<Uint8List?>();
    final frame = await waiting.future.timeout(timeout);
    if (frame == null) throw _closedError();
    return frame;
  }

  PairingFormatException _closedError() => PairingFormatException(
    _tooLong ? 'message too long' : 'the other device closed the connection',
  );

  void send(List<int> frame) {
    final header = Uint8List(4)
      ..[0] = (frame.length >> 24) & 0xFF
      ..[1] = (frame.length >> 16) & 0xFF
      ..[2] = (frame.length >> 8) & 0xFF
      ..[3] = frame.length & 0xFF;
    socket
      ..add(header)
      ..add(frame);
  }

  Future<void> close() async {
    try {
      await socket.flush();
    } on Object {
      // Already gone.
    }
    try {
      await socket.close();
    } on Object {
      // Already gone.
    }
    socket.destroy();
    await _subscription.cancel();
    _finish();
  }
}
