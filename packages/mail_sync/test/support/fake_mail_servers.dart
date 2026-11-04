// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

final _certs = Directory('../../test-server/.generated/certs');

/// Why tests with [FakeMailServers] are skipped (no test certificates),
/// or null.
String? get fakeServersSkipReason =>
    File('${_certs.path}/mail.crt').existsSync()
    ? null
    : 'needs the test certificates: run test-server/certs/generate.sh';

/// A tiny IMAP and SMTP server pair over implicit TLS, keeping mail in
/// memory: just enough of both for the outbox replay (sending, saving to
/// Sent, removing drafts, setting flags), so tests can count exactly what
/// reached "the server" without the docker test servers.
final class FakeMailServers {
  FakeMailServers._(this._imap, this._smtp);

  static Future<FakeMailServers> start() async {
    final context = SecurityContext()
      ..useCertificateChain('${_certs.path}/mail.crt')
      ..usePrivateKey('${_certs.path}/mail.key');
    final servers = FakeMailServers._(
      await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context),
      await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context),
    );
    servers._imap.listen(servers._imapSession, onError: (Object _) {});
    servers._smtp.listen(servers._smtpSession, onError: (Object _) {});
    return servers;
  }

  final SecureServerSocket _imap;
  final SecureServerSocket _smtp;

  /// Messages delivered over SMTP, as received.
  final delivered = <Uint8List>[];

  /// Folders and the messages appended to them.
  final folders = <String, List<Uint8List>>{
    'INBOX': [],
    'Sent': [],
    'Drafts': [],
  };

  /// IMAP commands received (without their tags), in order.
  final imapCommands = <String>[];

  /// Messages marked read on the server ("folder/uid").
  final seen = <String>{};

  /// Recipient addresses the SMTP server refuses (550).
  final refuse = <String>{};

  int get imapPort => _imap.port;
  int get smtpPort => _smtp.port;

  /// A connector that reaches these servers for any account.
  MailConnector connector() => DefaultMailConnector(
    const _AnyPassword(),
    tls: TlsSettings.trustOnly(File('${_certs.path}/ca.crt').readAsBytesSync()),
    useQresync: false,
    endpointFor: (s) => ServerEndpoint(
      'mail.citusmail.test',
      s.port == 465 ? smtpPort : imapPort,
      ConnectionSecurity.implicitTls,
      connectAddress: '127.0.0.1',
    ),
  );

  /// How many copies with this Message-ID were delivered.
  int deliveredCount(String messageId) =>
      delivered.where((m) => _messageId(m) == messageId).length;

  /// How many copies with this Message-ID are in [folder].
  int countIn(String folder, String messageId) => (folders[folder] ?? const [])
      .where((m) => _messageId(m) == messageId)
      .length;

  Future<void> close() async {
    await _imap.close();
    await _smtp.close();
  }

  static String? _messageId(Uint8List message) =>
      const MimeParser().parse(message).messageId;

  // -------------------------------------------------------------- IMAP

  void _imapSession(Socket socket) {
    socket.add(
      ascii.encode(
        '* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR LITERAL+ UIDPLUS] '
        'fake\r\n',
      ),
    );
    var buffer = <int>[];
    String? selected;
    ({String line, int length})? literal;

    String reply(String tag, String line) {
      imapCommands.add(line);
      final words = line.split(' ');
      var command = words.first.toUpperCase();
      if (command == 'UID') command = 'UID ${words[1].toUpperCase()}';
      String quoted(int i) =>
          RegExp(r'"([^"]*)"').allMatches(line).elementAt(i).group(1)!;
      switch (command) {
        case 'CAPABILITY':
          return '* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR LITERAL+ UIDPLUS\r\n'
              '$tag OK done\r\n';
        case 'AUTHENTICATE' || 'LOGIN' || 'NOOP' || 'ENABLE':
          return '$tag OK done\r\n';
        case 'SELECT' || 'EXAMINE':
          selected = quoted(0);
          final count = folders[selected]?.length ?? 0;
          return '* $count EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n'
              '* OK [UIDNEXT ${count + 1}] ok\r\n$tag OK [READ-WRITE] done\r\n';
        case 'UID SEARCH':
          final wanted = RegExp(
            r'HEADER "?Message-ID"? "?<?([^"\s>]+)>?"?',
            caseSensitive: false,
          ).firstMatch(line)?.group(1);
          final messages = folders[selected] ?? const <Uint8List>[];
          final found = [
            for (var i = 0; i < messages.length; i++)
              if (wanted == null || _messageId(messages[i]) == wanted) i + 1,
          ];
          return '* SEARCH${found.map((n) => ' $n').join()}\r\n'
              '$tag OK done\r\n';
        case 'UID FETCH':
          // The whole message, as asked (UIDs are positions here).
          final uid = int.parse(words[2]);
          final messages = folders[selected] ?? const <Uint8List>[];
          if (uid < 1 || uid > messages.length) return '$tag OK done\r\n';
          final raw = latin1.decode(messages[uid - 1]);
          // As a real server: BODY[] (not BODY.PEEK[]) marks it read.
          final peek = line.contains('BODY.PEEK[');
          if (!peek) seen.add('$selected/$uid');
          final flags = peek ? '' : r' FLAGS (\Seen)';
          return '* $uid FETCH (UID $uid$flags BODY[] {${raw.length}}\r\n'
              '$raw)\r\n$tag OK done\r\n';
        case 'UID STORE' || 'UID EXPUNGE':
          return '$tag OK done\r\n';
        case 'LOGOUT':
          return '* BYE bye\r\n$tag OK done\r\n';
        default:
          return '$tag BAD unknown\r\n';
      }
    }

    void append(String line, Uint8List message) {
      final tag = line.split(' ').first;
      final folder = RegExp(r'"([^"]*)"').firstMatch(line)!.group(1)!;
      final list = folders.putIfAbsent(folder, () => []);
      list.add(message);
      socket.add(ascii.encode('$tag OK [APPENDUID 1 ${list.length}] done\r\n'));
    }

    socket.listen(
      (data) {
        buffer.addAll(data);
        while (true) {
          if (literal case final pending?) {
            if (buffer.length < pending.length + 2) return;
            final message = Uint8List.fromList(
              buffer.sublist(0, pending.length),
            );
            final end = buffer.indexOf(0x0A, pending.length);
            if (end < 0) return;
            buffer = buffer.sublist(end + 1);
            literal = null;
            append(pending.line, message);
            continue;
          }
          final end = buffer.indexOf(0x0A);
          if (end < 0) return;
          final line = latin1.decode(buffer.sublist(0, end)).trimRight();
          buffer = buffer.sublist(end + 1);
          final size = RegExp(r'\{(\d+)\+\}$').firstMatch(line);
          if (size != null) {
            literal = (line: line, length: int.parse(size.group(1)!));
            continue;
          }
          final space = line.indexOf(' ');
          if (space < 0) continue;
          socket.add(
            latin1.encode(
              reply(line.substring(0, space), line.substring(space + 1)),
            ),
          );
        }
      },
      onError: (_) {},
      onDone: socket.destroy,
    );
  }

  // -------------------------------------------------------------- SMTP

  void _smtpSession(Socket socket) {
    socket.add(ascii.encode('220 fake ESMTP\r\n'));
    var buffer = <int>[];
    BytesBuilder? data;
    socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        while (true) {
          final end = buffer.indexOf(0x0A);
          if (end < 0) return;
          final raw = buffer.sublist(0, end + 1);
          buffer = buffer.sublist(end + 1);
          if (data case final message?) {
            if (latin1.decode(raw) == '.\r\n') {
              delivered.add(message.takeBytes());
              data = null;
              socket.add(ascii.encode('250 queued\r\n'));
            } else {
              // Undo dot-stuffing.
              message.add(
                raw.length > 1 && raw[0] == 0x2E && raw[1] == 0x2E
                    ? raw.sublist(1)
                    : raw,
              );
            }
            continue;
          }
          final line = latin1.decode(raw).trimRight();
          final verb = line.split(RegExp('[ :]')).first.toUpperCase();
          final answer = switch (verb) {
            'EHLO' => '250-fake\r\n250 AUTH PLAIN\r\n',
            'AUTH' => '235 ok\r\n',
            'MAIL' || 'RSET' => '250 ok\r\n',
            'RCPT' when refuse.any((r) => line.contains('<$r>')) =>
              '550 no such mailbox\r\n',
            'RCPT' => '250 ok\r\n',
            'DATA' => () {
              data = BytesBuilder();
              return '354 go ahead\r\n';
            }(),
            'QUIT' => '221 bye\r\n',
            _ => '502 unknown\r\n',
          };
          socket.add(ascii.encode(answer));
        }
      },
      onError: (_) {},
      onDone: socket.destroy,
    );
  }
}

final class _AnyPassword implements CredentialProvider {
  const _AnyPassword();

  @override
  Future<String> passwordFor(Account account) async => 'test-password';
}
