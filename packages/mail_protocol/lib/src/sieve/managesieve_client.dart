// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import '../net/mail_exception.dart';
import '../net/mail_socket.dart';
import '../net/server_endpoint.dart';
import '../net/xoauth2.dart';

/// Timeouts for ManageSieve. Short: it runs alongside mail sync, and a
/// server without it should not hold anything up.
final class ManageSieveTimeouts {
  const ManageSieveTimeouts({
    this.connect = const Duration(seconds: 10),
    this.command = const Duration(seconds: 30),
  });

  final Duration connect;
  final Duration command;
}

/// What the server announced (RFC 5804 1.7).
final class SieveCapabilities {
  SieveCapabilities._(this._values);

  final Map<String, String> _values;

  /// e.g. `Dovecot Pigeonhole`.
  String? get implementation => _values['IMPLEMENTATION'];

  /// Sieve extensions the server's interpreter supports (`fileinto`...).
  Set<String> get extensions => _words('SIEVE');

  /// SASL mechanisms, upper case.
  Set<String> get sasl => _words('SASL').map((m) => m.toUpperCase()).toSet();

  bool get startTls => _values.containsKey('STARTTLS');

  /// Present from RFC 5804 on; CHECKSCRIPT needs it.
  String? get version => _values['VERSION'];

  Set<String> _words(String key) => {
    for (final word in (_values[key] ?? '').split(' '))
      if (word.isNotEmpty) word,
  };
}

/// A script stored on the server.
final class SieveScriptInfo {
  const SieveScriptInfo(this.name, {required this.active});

  final String name;

  /// At most one script is active: the one the server runs.
  final bool active;

  @override
  String toString() => 'SieveScriptInfo($name${active ? ', active' : ''})';
}

/// The server answered NO (or BYE).
final class ManageSieveException extends MailException {
  ManageSieveException(this.command, this.code, String text)
    : text = text.length > 300 ? text.substring(0, 300) : text,
      super('$command refused${code == null ? '' : ' ($code)'}: $text');

  final String command;

  /// The response code, upper case: `NONEXISTENT`, `QUOTA`, `ACTIVE`...
  final String? code;

  /// The server's explanation (for a script, the error it found).
  final String text;
}

/// The server refused the login.
final class ManageSieveAuthenticationException extends MailException {
  const ManageSieveAuthenticationException(super.message);
}

/// A ManageSieve client (RFC 5804) for one connection: stores, checks and
/// activates the Sieve scripts (RFC 5228) that sort mail on the server as
/// it arrives.
///
/// Like the IMAP and SMTP clients, it only talks over TLS: STARTTLS is
/// required before anything else is sent, and credentials are refused on
/// an unencrypted connection. Any connection-level failure closes it.
final class ManageSieveClient {
  ManageSieveClient._(this._socket, this.endpoint, this.timeouts);

  /// The standard port.
  static const port = 4190;

  final MailSocket _socket;
  final ServerEndpoint endpoint;
  final ManageSieveTimeouts timeouts;

  late SieveCapabilities _capabilities;
  MailException? _broken;

  SieveCapabilities get capabilities => _capabilities;

  /// Connects, reads the capabilities and upgrades to TLS. Only
  /// [ConnectionSecurity.startTls] is defined for ManageSieve; an
  /// implicit-TLS endpoint is accepted too (some servers offer one).
  static Future<ManageSieveClient> connect(
    ServerEndpoint endpoint, {
    TlsSettings tls = const TlsSettings(),
    ManageSieveTimeouts timeouts = const ManageSieveTimeouts(),
  }) async {
    final socket = await MailSocket.connect(
      endpoint,
      tls: tls,
      timeout: timeouts.connect,
    );
    final client = ManageSieveClient._(socket, endpoint, timeouts);
    try {
      await client._start();
      return client;
    } on Object {
      await socket.close();
      rethrow;
    }
  }

  Future<void> _start() async {
    _capabilities = await _readCapabilities('greeting');
    if (_socket.isSecure) return;
    if (!_capabilities.startTls) {
      throw const MailSecurityException(
        'the server does not offer STARTTLS; refusing to continue unencrypted',
      );
    }
    await _run('STARTTLS', 'STARTTLS');
    await _socket.startTls();
    // RFC 5804 2.2: the server sends its capabilities again after TLS.
    _capabilities = await _readCapabilities('STARTTLS');
  }

  /// Logs in with SASL PLAIN.
  Future<void> authenticate(String username, String password) async {
    _requireSecure();
    if (!_capabilities.sasl.contains('PLAIN')) {
      throw const ManageSieveAuthenticationException(
        'the server offers no login this app supports',
      );
    }
    final token = base64.encode(utf8.encode('\u0000$username\u0000$password'));
    await _authenticate('PLAIN', token);
  }

  /// Logs in with an OAuth 2.0 access token (SASL XOAUTH2).
  Future<void> authenticateOAuth(String username, String accessToken) async {
    _requireSecure();
    if (!_capabilities.sasl.contains('XOAUTH2')) {
      throw const ManageSieveAuthenticationException(
        'the server does not accept OAuth sign-in here',
      );
    }
    await _authenticate(
      'XOAUTH2',
      XOAuth2.initialResponse(username, accessToken),
    );
  }

  Future<void> _authenticate(String mechanism, String initial) async {
    _checkUsable();
    await _write(
      utf8.encode('AUTHENTICATE ${_quote(mechanism)} ${_quote(initial)}\r\n'),
    );
    while (true) {
      final line = await _readLine();
      final status = _status(line);
      if (status == null) {
        // A challenge: the server is refusing (XOAUTH2 sends its reason
        // this way). Cancel the exchange (RFC 5804 2.1).
        await _write(utf8.encode('"*"\r\n'));
        continue;
      }
      if (status == 'OK') return;
      throw ManageSieveAuthenticationException(
        'login refused by the server: ${_text(line) ?? status}',
      );
    }
  }

  /// The scripts on the server.
  Future<List<SieveScriptInfo>> listScripts() async {
    final lines = await _run('LISTSCRIPTS', 'LISTSCRIPTS');
    return [
      for (final line in lines)
        if (line.isNotEmpty && line.first is _Str)
          SieveScriptInfo(
            (line.first as _Str).value,
            active:
                line.length > 1 &&
                line[1] is _Atom &&
                (line[1] as _Atom).value.toUpperCase() == 'ACTIVE',
          ),
    ];
  }

  /// A script's text. Throws [ManageSieveException] (NONEXISTENT) if
  /// there is none by that name.
  Future<String> getScript(String name) async {
    final lines = await _run('GETSCRIPT', 'GETSCRIPT ${_quote(name)}');
    for (final line in lines) {
      if (line.isNotEmpty && line.first is _Str) {
        return (line.first as _Str).value;
      }
    }
    return '';
  }

  /// Checks [script] without storing it. Returns the server's warnings,
  /// if any; throws [ManageSieveException] with the error it found.
  Future<String?> checkScript(String script) =>
      _withScript('CHECKSCRIPT', 'CHECKSCRIPT', script);

  /// Stores [script] as [name], replacing one by that name (also the
  /// active one, which then runs the new text at once). The server checks
  /// it first: an invalid script is refused and nothing changes. Returns
  /// the server's warnings, if any.
  Future<String?> putScript(String name, String script) =>
      _withScript('PUTSCRIPT', 'PUTSCRIPT ${_quote(name)}', script);

  /// Makes [name] the script the server runs; null runs none.
  Future<void> setActive(String? name) async {
    await _run('SETACTIVE', 'SETACTIVE ${_quote(name ?? '')}');
  }

  /// Deletes a script (the server refuses to delete the active one).
  Future<void> deleteScript(String name) async {
    await _run('DELETESCRIPT', 'DELETESCRIPT ${_quote(name)}');
  }

  /// Ends the session politely and closes the connection.
  Future<void> logout() async {
    try {
      if (_broken == null) {
        await _write(utf8.encode('LOGOUT\r\n'));
        await _readLine();
      }
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

  // ---------------------------------------------------------------------

  void _requireSecure() {
    if (!_socket.isSecure) {
      throw const MailSecurityException(
        'refusing to send credentials over an unencrypted connection',
      );
    }
  }

  Future<String?> _withScript(
    String name,
    String command,
    String script,
  ) async {
    final bytes = utf8.encode(script);
    final out = BytesBuilder(copy: false)
      ..add(utf8.encode('$command {${bytes.length}+}\r\n'))
      ..add(bytes)
      ..add(const [0x0D, 0x0A]);
    final (_, done) = await _send(name, out.takeBytes());
    return _code(done) == 'WARNINGS' ? _text(done) : null;
  }

  /// Sends [line] (without CRLF) and returns the lines before OK.
  Future<List<List<_Token>>> _run(String name, String line) async {
    if (line.contains('\r') || line.contains('\n')) {
      throw ArgumentError('a ManageSieve command must be a single line');
    }
    final (lines, _) = await _send(name, utf8.encode('$line\r\n'));
    return lines;
  }

  Future<(List<List<_Token>>, List<_Token>)> _send(
    String name,
    List<int> bytes,
  ) async {
    _checkUsable();
    await _write(bytes);
    final lines = <List<_Token>>[];
    while (true) {
      final line = await _readLine();
      final status = _status(line);
      if (status == null) {
        if (lines.length > 10000) {
          throw const MailProtocolException('the server sent too much');
        }
        lines.add(line);
        continue;
      }
      if (status == 'OK') return (lines, line);
      if (status == 'BYE') {
        _broken = MailConnectionException(
          'the server closed the session: ${_text(line) ?? ''}',
        );
        await _socket.close();
      }
      throw ManageSieveException(name, _code(line), _text(line) ?? status);
    }
  }

  Future<SieveCapabilities> _readCapabilities(String during) async {
    final values = <String, String>{};
    while (true) {
      final line = await _readLine();
      final status = _status(line);
      if (status == 'OK') return SieveCapabilities._(Map.unmodifiable(values));
      if (status != null) {
        throw MailConnectionException(
          'the server refused the connection ($during): ${_text(line) ?? status}',
        );
      }
      if (line.isEmpty || line.first is! _Str) {
        throw const MailProtocolException('not a ManageSieve capability');
      }
      final key = (line.first as _Str).value.toUpperCase();
      values[key] = line.length > 1 && line[1] is _Str
          ? (line[1] as _Str).value
          : '';
    }
  }

  static String? _status(List<_Token> line) {
    if (line.isEmpty || line.first is! _Atom) return null;
    final word = (line.first as _Atom).value.toUpperCase();
    return word == 'OK' || word == 'NO' || word == 'BYE' ? word : null;
  }

  static String? _code(List<_Token> line) {
    final code = line.whereType<_Code>().firstOrNull;
    return code?.value.split(' ').first.toUpperCase();
  }

  static String? _text(List<_Token> line) =>
      line.whereType<_Str>().firstOrNull?.value;

  /// A quoted string (RFC 5804 4): only for short, single-line values.
  static String _quote(String value) {
    if (value.contains('\r') || value.contains('\n') || value.length > 1024) {
      throw ArgumentError.value(value, 'value', 'not usable in a command');
    }
    return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  Future<void> _write(List<int> bytes) async {
    try {
      await _socket.write(bytes);
    } on MailException catch (e) {
      _broken = e;
      await _socket.close();
      rethrow;
    }
  }

  /// Reads one response line as tokens: atoms, strings (quoted or
  /// literal, read in full) and a parenthesised response code.
  Future<List<_Token>> _readLine() async {
    try {
      final tokens = <_Token>[];
      var text = latin1.decode(
        await _socket.readLine(timeout: timeouts.command),
      );
      var i = 0;
      while (true) {
        while (i < text.length && text[i] == ' ') {
          i++;
        }
        if (i >= text.length) return tokens;
        final c = text[i];
        if (c == '"') {
          final out = StringBuffer();
          i++;
          while (true) {
            if (i >= text.length) {
              throw const MailProtocolException('an unterminated string');
            }
            final ch = text[i];
            if (ch == r'\' && i + 1 < text.length) {
              out.write(text[i + 1]);
              i += 2;
            } else if (ch == '"') {
              i++;
              break;
            } else {
              out.write(ch);
              i++;
            }
          }
          tokens.add(_Str(_utf8(out.toString())));
        } else if (c == '{') {
          final end = text.indexOf('}', i);
          final match = end < 0
              ? null
              : RegExp(r'^\{(\d{1,9})\+?\}$')
                    .firstMatch(text.substring(i, end + 1));
          if (match == null || end != text.length - 1) {
            throw const MailProtocolException('a malformed literal');
          }
          final length = int.parse(match.group(1)!);
          if (length > 1024 * 1024) {
            throw const MailProtocolException('a literal that is too large');
          }
          final data = await _socket.readBytes(
            length,
            timeout: timeouts.command,
          );
          tokens.add(_Str(utf8.decode(data, allowMalformed: true)));
          // The line goes on after the literal.
          text = latin1.decode(
            await _socket.readLine(timeout: timeouts.command),
          );
          i = 0;
        } else if (c == '(') {
          // A response code may hold a quoted string with ")" in it.
          var depth = 0, j = i, quoted = false;
          for (; j < text.length; j++) {
            final ch = text[j];
            if (quoted) {
              if (ch == r'\') {
                j++;
              } else if (ch == '"') {
                quoted = false;
              }
            } else if (ch == '"') {
              quoted = true;
            } else if (ch == '(') {
              depth++;
            } else if (ch == ')' && --depth == 0) {
              break;
            }
          }
          if (j >= text.length) {
            throw const MailProtocolException('a malformed response code');
          }
          tokens.add(_Code(text.substring(i + 1, j)));
          i = j + 1;
        } else {
          var j = i;
          while (j < text.length && text[j] != ' ') {
            j++;
          }
          tokens.add(_Atom(text.substring(i, j)));
          i = j;
        }
      }
    } on MailException catch (e) {
      _broken ??= e;
      await _socket.close();
      rethrow;
    }
  }

  /// Quoted strings arrive as latin1-decoded bytes; they are UTF-8.
  static String _utf8(String latin) =>
      utf8.decode(latin1.encode(latin), allowMalformed: true);

  void _checkUsable() {
    final broken = _broken;
    if (broken != null) throw broken;
  }
}

sealed class _Token {
  const _Token(this.value);

  final String value;
}

final class _Atom extends _Token {
  const _Atom(super.value);
}

final class _Str extends _Token {
  const _Str(super.value);
}

final class _Code extends _Token {
  const _Code(super.value);
}
