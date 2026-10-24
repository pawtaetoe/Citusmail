// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import '../mime/address.dart';
import '../mime/builder/header_encoder.dart';
import '../mime/builder/outgoing_message.dart';
import '../net/mail_exception.dart';
import '../net/mail_socket.dart';
import '../net/server_endpoint.dart';
import '../net/xoauth2.dart';
import 'smtp_reply.dart';

/// Timeouts for SMTP (RFC 5321 4.5.3.2 suggests these minimums).
final class SmtpTimeouts {
  const SmtpTimeouts({
    this.connect = const Duration(seconds: 30),
    this.command = const Duration(minutes: 2),
    this.dataEnd = const Duration(minutes: 10),
  });

  final Duration connect;
  final Duration command;

  /// Wait for the final reply after the message: servers may scan it first.
  final Duration dataEnd;
}

/// An SMTP submission client (RFC 5321, RFC 6409) for one connection.
///
/// Like [ImapClient], any connection-level failure closes the connection;
/// the caller reconnects.
final class SmtpClient {
  SmtpClient._(this._socket, this.endpoint, this.timeouts, this.heloName);

  final MailSocket _socket;
  final ServerEndpoint endpoint;
  final SmtpTimeouts timeouts;

  /// Sent in EHLO. The default address literal reveals nothing about the
  /// device (a hostname such as "alice-laptop" would).
  final String heloName;

  Map<String, String> _extensions = const {};
  bool _authenticated = false;
  MailException? _broken;

  /// EHLO extensions, upper-case keyword -> parameters.
  Map<String, String> get extensions => _extensions;

  bool get isAuthenticated => _authenticated;

  /// Largest accepted message (SIZE extension), or null if not announced.
  int? get maxMessageSize {
    final value = int.tryParse(_extensions['SIZE'] ?? '');
    return value == null || value == 0 ? null : value;
  }

  /// Connects, greets the server and, for [ConnectionSecurity.startTls],
  /// upgrades to TLS (refusing servers that do not offer it).
  static Future<SmtpClient> connect(
    ServerEndpoint endpoint, {
    TlsSettings tls = const TlsSettings(),
    SmtpTimeouts timeouts = const SmtpTimeouts(),
    String heloName = '[127.0.0.1]',
  }) async {
    if (!RegExp(r'^[A-Za-z0-9.\-\[\]:]+$').hasMatch(heloName)) {
      throw ArgumentError.value(
        heloName,
        'heloName',
        'not a host name or address literal',
      );
    }
    final socket = await MailSocket.connect(
      endpoint,
      tls: tls,
      timeout: timeouts.connect,
    );
    final client = SmtpClient._(socket, endpoint, timeouts, heloName);
    try {
      await client._start();
      return client;
    } on Object {
      await socket.close();
      rethrow;
    }
  }

  Future<void> _start() async {
    final greeting = await _read();
    if (greeting.code != 220) {
      throw MailConnectionException(
        'the server refused the connection: $greeting',
      );
    }
    await _ehlo();
    if (endpoint.security == ConnectionSecurity.startTls) {
      if (!_extensions.containsKey('STARTTLS')) {
        throw const MailSecurityException(
          'the server does not offer STARTTLS; refusing to continue unencrypted',
        );
      }
      await _command('STARTTLS', expect: 220);
      await _socket.startTls();
      // RFC 3207 4.2: forget everything learned before TLS, greet again.
      _extensions = const {};
      await _ehlo();
    }
  }

  Future<void> _ehlo() async {
    final reply = await _command('EHLO $heloName', name: 'EHLO', expect: 250);
    final extensions = <String, String>{};
    for (final line in reply.lines.skip(1)) {
      final space = line.indexOf(' ');
      final key = (space < 0 ? line : line.substring(0, space)).toUpperCase();
      extensions[key] = space < 0 ? '' : line.substring(space + 1).trim();
    }
    _extensions = Map.unmodifiable(extensions);
  }

  /// Logs in with AUTH PLAIN, or AUTH LOGIN if that is all the server
  /// offers. Refuses to run on an unencrypted connection.
  Future<void> authenticate(String username, String password) async {
    if (!_socket.isSecure) {
      throw const MailSecurityException(
        'refusing to send credentials over an unencrypted connection',
      );
    }
    final mechanisms = (_extensions['AUTH'] ?? '').toUpperCase().split(' ');
    try {
      if (mechanisms.contains('PLAIN')) {
        final token = base64.encode(
          utf8.encode('\u0000$username\u0000$password'),
        );
        await _command('AUTH PLAIN $token', name: 'AUTH', expect: 235);
      } else if (mechanisms.contains('LOGIN')) {
        await _command('AUTH LOGIN', name: 'AUTH', expect: 334);
        await _command(
          base64.encode(utf8.encode(username)),
          name: 'AUTH',
          expect: 334,
        );
        await _command(
          base64.encode(utf8.encode(password)),
          name: 'AUTH',
          expect: 235,
        );
      } else {
        throw SmtpAuthenticationException(null);
      }
    } on SmtpReplyException catch (e) {
      throw SmtpAuthenticationException(e.reply);
    }
    _authenticated = true;
  }

  /// Logs in with an OAuth 2.0 access token (SASL XOAUTH2). Refuses an
  /// unencrypted connection.
  Future<void> authenticateOAuth(String username, String accessToken) async {
    if (!_socket.isSecure) {
      throw const MailSecurityException(
        'refusing to send credentials over an unencrypted connection',
      );
    }
    final mechanisms = (_extensions['AUTH'] ?? '').toUpperCase().split(' ');
    if (!mechanisms.contains('XOAUTH2')) {
      throw SmtpAuthenticationException(null);
    }
    final token = XOAuth2.initialResponse(username, accessToken);
    final reply = await _exchange('AUTH XOAUTH2 $token');
    if (reply.code == 334) {
      // The refusal comes as a challenge; an empty line ends the exchange.
      throw SmtpAuthenticationException(await _exchange(''));
    }
    if (reply.code != 235) throw SmtpAuthenticationException(reply);
    _authenticated = true;
  }

  /// Sends [message] from [from]. If any recipient is refused, nothing is
  /// sent (the transaction is reset) and [SmtpRecipientsRejectedException]
  /// lists who was refused, so the user decides what to do.
  Future<void> send(BuiltMessage message, {required MailAddress from}) async {
    const encoder = HeaderEncoder();
    final sender = encoder.validateAddress(from);
    final recipients = [
      for (final r in message.recipients) (r, encoder.validateAddress(r)),
    ];
    if (recipients.isEmpty) throw const MessageBuildException('no recipients');

    final data = dotStuff(message.bytes);
    final limit = maxMessageSize;
    if (limit != null && data.length > limit) {
      throw SmtpMessageTooLargeException(data.length, limit);
    }

    final sizeParameter = _extensions.containsKey('SIZE')
        ? ' SIZE=${data.length}'
        : '';
    await _command(
      'MAIL FROM:<$sender>$sizeParameter',
      name: 'MAIL FROM',
      expect: 250,
    );

    final rejected = <MailAddress, SmtpReply>{};
    for (final (recipient, address) in recipients) {
      final reply = await _exchange('RCPT TO:<$address>');
      if (reply.code != 250 && reply.code != 251) rejected[recipient] = reply;
    }
    if (rejected.isNotEmpty) {
      await _reset();
      throw SmtpRecipientsRejectedException(rejected);
    }

    await _command('DATA', expect: 354);
    await _socket.write(data);
    await _socket.write(ascii.encode('.\r\n'));
    final reply = await _read(timeout: timeouts.dataEnd);
    if (reply.code != 250) throw SmtpReplyException('DATA', reply);
  }

  /// Ends the session politely and closes the connection.
  Future<void> quit() async {
    try {
      if (_broken == null) await _command('QUIT', expect: 221);
    } on MailException {
      // Closing anyway.
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    _broken ??= const MailConnectionException('connection closed');
    await _socket.close();
  }

  /// RFC 5321 4.5.2: a line starting with "." gets another ".", so a line
  /// of just "." in the message cannot end it early. Also guarantees the
  /// message ends with CRLF before the terminating ".".
  static Uint8List dotStuff(Uint8List message) {
    final out = BytesBuilder(copy: false);
    var lineStart = true;
    for (var i = 0; i < message.length; i++) {
      final b = message[i];
      if (lineStart && b == 0x2E) out.addByte(0x2E);
      out.addByte(b);
      lineStart = b == 0x0A;
    }
    if (message.length < 2 ||
        message[message.length - 2] != 0x0D ||
        message[message.length - 1] != 0x0A) {
      out.add(const [0x0D, 0x0A]);
    }
    return out.takeBytes();
  }

  // ---------------------------------------------------------------------

  Future<void> _reset() async {
    try {
      await _command('RSET', expect: 250);
    } on SmtpReplyException {
      await close(); // cannot get back to a clean state
    }
  }

  /// Sends [line] and requires reply code [expect].
  Future<SmtpReply> _command(
    String line, {
    required int expect,
    String? name,
  }) async {
    final reply = await _exchange(line);
    if (reply.code != expect) {
      throw SmtpReplyException(name ?? line.split(' ').first, reply);
    }
    return reply;
  }

  /// Sends [line] and returns whatever the server replies.
  Future<SmtpReply> _exchange(String line) async {
    _checkUsable();
    if (line.contains('\r') || line.contains('\n')) {
      throw ArgumentError('SMTP command must be a single line');
    }
    try {
      await _socket.write(utf8.encode('$line\r\n'));
      return await _read();
    } on MailException catch (e) {
      _broken = e;
      await _socket.close();
      rethrow;
    }
  }

  Future<SmtpReply> _read({Duration? timeout}) async {
    try {
      final reply = await SmtpReply.read(
        _socket,
        timeout: timeout ?? timeouts.command,
      );
      // 421: the server is closing the connection.
      if (reply.code == 421) {
        _broken = MailConnectionException(
          'the server closed the session: $reply',
        );
        await _socket.close();
        throw _broken!;
      }
      return reply;
    } on MailException catch (e) {
      _broken ??= e;
      await _socket.close();
      rethrow;
    }
  }

  void _checkUsable() {
    final broken = _broken;
    if (broken != null) throw broken;
  }
}
