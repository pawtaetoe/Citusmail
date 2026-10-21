// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'line_source.dart';
import 'mail_exception.dart';
import 'server_endpoint.dart';

/// Limits on what a server may send, so a broken or hostile server cannot
/// exhaust memory.
final class MailSocketLimits {
  const MailSocketLimits({
    this.maxLineLength = 8 * 1024 * 1024,
    this.maxBufferedBytes = 64 * 1024 * 1024,
  });

  /// Longest line accepted (IMAP sends large data as literals, not lines).
  final int maxLineLength;

  /// Reading pauses when this much unread data is waiting.
  final int maxBufferedBytes;
}

/// A buffered connection to a mail server for line-based protocols.
///
/// Built on [RawSocket] so a plain connection can be upgraded in place with
/// STARTTLS. Reads are pull-based ([readLine], [readBytes]) with timeouts.
final class MailSocket implements LineSource {
  MailSocket._(
    this._socket,
    this.host,
    this.limits,
    this._tls, {
    required this._secure,
  }) {
    _listen();
  }

  final String host;
  final MailSocketLimits limits;
  final TlsSettings _tls;

  RawSocket _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  bool _secure;

  // Received, not yet consumed: _buffer[_start, _end).
  Uint8List _buffer = Uint8List(16 * 1024);
  int _start = 0;
  int _end = 0;

  // Pending outgoing chunks; the first one is partly sent up to _outOffset.
  final List<Uint8List> _outbox = [];
  int _outOffset = 0;
  Completer<void>? _drained;

  Completer<void>? _dataWaiter;
  bool _readClosed = false;
  bool _closed = false;
  Object? _error;

  /// Whether the connection is encrypted.
  bool get isSecure => _secure;

  /// Whether unread received data is waiting.
  bool get hasBufferedData => _end > _start;

  /// Connects to [endpoint]. For [ConnectionSecurity.implicitTls] the TLS
  /// handshake (with full certificate and host name checks) completes
  /// before this returns.
  static Future<MailSocket> connect(
    ServerEndpoint endpoint, {
    TlsSettings tls = const TlsSettings(),
    Duration timeout = const Duration(seconds: 30),
    MailSocketLimits limits = const MailSocketLimits(),
  }) async {
    // The certificate is always rejected when the trust store rejects it;
    // it is only remembered to explain the error.
    X509Certificate? rejected;
    try {
      final address = endpoint.connectAddress ?? endpoint.host;
      RawSocket socket = await RawSocket.connect(
        address,
        endpoint.port,
        timeout: timeout,
      );
      if (endpoint.security == ConnectionSecurity.implicitTls) {
        try {
          socket = await RawSecureSocket.secure(
            socket,
            host: endpoint.host, // SNI and certificate name check
            context: tls.createContext(),
            onBadCertificate: (certificate) {
              rejected = certificate;
              return false; // never accept what the trust store rejects
            },
          ).timeout(timeout);
        } on Object {
          await socket.close();
          rethrow;
        }
      }
      return MailSocket._(
        socket,
        endpoint.host,
        limits,
        tls,
        secure: endpoint.security == ConnectionSecurity.implicitTls,
      );
    } on TlsException catch (e) {
      throw _tlsError(e, endpoint.host, rejected);
    } on SocketException catch (e) {
      final text = e.toString();
      if (text.toLowerCase().contains('timed out')) {
        throw MailTimeoutException('connecting to $endpoint timed out');
      }
      throw MailConnectionException(
        'cannot connect to $endpoint: ${e.message}',
      );
    } on TimeoutException {
      throw MailTimeoutException('TLS handshake with $endpoint timed out');
    }
  }

  static MailTlsException _tlsError(
    TlsException e,
    String host,
    X509Certificate? rejected,
  ) => MailTlsException(
    MailTlsException.classify(e.toString()),
    'TLS with $host failed: ${e.message}',
    certificate: rejected == null
        ? null
        : RejectedCertificate(
            subject: rejected.subject,
            issuer: rejected.issuer,
            validFrom: rejected.startValidity,
            validUntil: rejected.endValidity,
          ),
  );

  /// Upgrades this plain connection to TLS after the server accepted
  /// STARTTLS.
  ///
  /// If any data arrived after the server's STARTTLS reply, it was sent
  /// unencrypted by the server or injected by an attacker in between
  /// (CVE-2011-0411 class). That data must never be treated as coming over
  /// TLS, so the connection is closed instead.
  Future<void> startTls() async {
    if (_secure) throw StateError('already secure');
    if (hasBufferedData) {
      await close();
      throw const MailSecurityException(
        'the server sent unencrypted data after accepting STARTTLS; connection closed',
      );
    }
    // Handed over, not cancelled: RawSecureSocket.secure takes ownership of
    // the subscription and continues it over TLS. No await happens between
    // the buffer check above and this hand-over, so no plain-text data can
    // be read in between (and Dart requires the subscription unpaused).
    // ignore: cancel_subscriptions
    final subscription = _subscription!;
    _subscription = null;
    X509Certificate? rejected;
    try {
      _socket = await RawSecureSocket.secure(
        _socket,
        subscription: subscription,
        host: host,
        context: _tls.createContext(),
        onBadCertificate: (certificate) {
          rejected = certificate;
          return false;
        },
      );
    } on TlsException catch (e) {
      _closed = true;
      throw _tlsError(e, host, rejected);
    }
    _secure = true;
    _listen();
  }

  /// Reads one line, without its line ending (CRLF, or a bare LF).
  @override
  Future<Uint8List> readLine({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // How many unread bytes are already known to contain no line feed.
    // Relative to _start, because the buffer may be compacted while waiting.
    var scanned = 0;
    while (true) {
      for (var i = _start + scanned; i < _end; i++) {
        if (_buffer[i] == 0x0A) {
          final lineEnd = i > _start && _buffer[i - 1] == 0x0D ? i - 1 : i;
          final line = Uint8List.fromList(
            Uint8List.sublistView(_buffer, _start, lineEnd),
          );
          _consume(i + 1 - _start);
          return line;
        }
      }
      if (_end - _start > limits.maxLineLength) {
        throw const MailProtocolException(
          'the server sent a line that is too long',
        );
      }
      scanned = _end - _start;
      await _waitForData(timeout);
    }
  }

  /// Reads exactly [length] bytes (for IMAP literals).
  @override
  Future<Uint8List> readBytes(
    int length, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final out = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      if (_end == _start) await _waitForData(timeout);
      final take = (_end - _start) < (length - filled)
          ? _end - _start
          : length - filled;
      out.setRange(filled, filled + take, _buffer, _start);
      filled += take;
      _consume(take);
    }
    return out;
  }

  /// Sends [bytes]; completes when they have been handed to the OS.
  Future<void> write(List<int> bytes) {
    _checkOpen();
    if (bytes.isEmpty) return Future.value();
    _outbox.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _flush();
    if (_outbox.isEmpty) return Future.value();
    return (_drained ??= Completer<void>()).future;
  }

  /// Closes the connection. Safe to call more than once.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket.close();
    } on Object {
      // Already gone.
    }
    _failWaiters(const MailConnectionException('connection closed'));
  }

  // ---------------------------------------------------------------------

  void _listen() {
    _subscription = _socket.listen(
      _onEvent,
      onError: (Object error) {
        _error = error;
        _failWaiters(_describe(error));
      },
      onDone: () {
        _readClosed = true;
        _wakeReader();
      },
      cancelOnError: true,
    );
  }

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        final data = _socket.read();
        if (data != null && data.isNotEmpty) {
          _append(data);
          if (_end - _start > limits.maxBufferedBytes) {
            _socket.readEventsEnabled = false;
          }
          _wakeReader();
        }
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed:
        _readClosed = true;
        _wakeReader();
      case RawSocketEvent.closed:
        _readClosed = true;
        _wakeReader();
    }
  }

  void _flush() {
    while (_outbox.isNotEmpty && !_closed) {
      final chunk = _outbox.first;
      final written = _socket.write(chunk, _outOffset);
      if (written <= 0) {
        _socket.writeEventsEnabled = true; // continue on the next write event
        return;
      }
      _outOffset += written;
      if (_outOffset == chunk.length) {
        _outbox.removeAt(0);
        _outOffset = 0;
      }
    }
    final drained = _drained;
    if (_outbox.isEmpty && drained != null) {
      _drained = null;
      drained.complete();
    }
  }

  void _append(Uint8List data) {
    if (_end + data.length > _buffer.length) {
      final unread = _end - _start;
      if (unread + data.length <= _buffer.length) {
        _buffer.setRange(0, unread, _buffer, _start); // compact in place
      } else {
        var size = _buffer.length;
        while (size < unread + data.length) {
          size *= 2;
        }
        final grown = Uint8List(size)..setRange(0, unread, _buffer, _start);
        _buffer = grown;
      }
      _end = unread;
      _start = 0;
    }
    _buffer.setRange(_end, _end + data.length, data);
    _end += data.length;
  }

  void _consume(int count) {
    _start += count;
    if (_start == _end) _start = _end = 0;
    if (!_socket.readEventsEnabled &&
        _end - _start <= limits.maxBufferedBytes &&
        !_closed) {
      _socket.readEventsEnabled = true;
    }
  }

  Future<void> _waitForData(Duration timeout) async {
    final error = _error;
    if (error != null) throw _describe(error);
    if (_readClosed || _closed) {
      throw const MailConnectionException('the server closed the connection');
    }
    final waiter = _dataWaiter = Completer<void>();
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw MailTimeoutException(
        'no reply from $host for ${timeout.inSeconds} s',
      );
    } finally {
      if (identical(_dataWaiter, waiter)) _dataWaiter = null;
    }
  }

  void _wakeReader() {
    final waiter = _dataWaiter;
    _dataWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _failWaiters(MailException error) {
    final waiter = _dataWaiter;
    _dataWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.completeError(error);
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.completeError(error);
  }

  void _checkOpen() {
    if (_closed) throw const MailConnectionException('connection closed');
    final error = _error;
    if (error != null) throw _describe(error);
  }

  MailException _describe(Object error) => switch (error) {
    HandshakeException() => MailTlsException(
      MailTlsException.classify(error.toString()),
      error.message,
    ),
    TlsException() => MailTlsException(
      MailTlsException.classify(error.toString()),
      error.message,
    ),
    SocketException() => MailConnectionException(error.message),
    MailException() => error,
    _ => MailConnectionException(error.toString()),
  };
}
