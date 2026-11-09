// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'fake_mail_servers.dart' show fakeServersSkipReason;

export 'fake_mail_servers.dart' show fakeServersSkipReason;

final _certs = Directory('../../test-server/.generated/certs');

/// A message on [FakeImap].
final class FakeMessage {
  FakeMessage(this.uid, this.raw, this.flags, this.modSeq, this.date);

  final int uid;
  final Uint8List raw;
  Set<String> flags;
  int modSeq;
  final DateTime date;
}

/// A folder on [FakeImap], with real UIDs: removing a message never
/// renumbers the others.
final class FakeFolder {
  FakeFolder({this.specialUse});

  final String? specialUse;
  int uidValidity = 1;
  int uidNext = 1;
  int highestModSeq = 1;
  final messages = <FakeMessage>[];

  /// Adds a simple message from [from] and returns it.
  FakeMessage add({
    String subject = 'Hello',
    String from = 'ana@x.example',
    String? messageId,
    DateTime? date,
    Set<String> flags = const {},
    Uint8List? raw,
  }) {
    final uid = uidNext++;
    final at = date ?? DateTime.utc(2026, 10, 1).add(Duration(minutes: uid));
    final message = FakeMessage(
      uid,
      raw ??
          Uint8List.fromList(
            utf8.encode(
              'From: $from\r\n'
              'To: alice@citusmail.test\r\n'
              'Subject: $subject\r\n'
              'Message-ID: <${messageId ?? 'm$uid-$uidValidity@x.example'}>\r\n'
              '\r\n'
              'Hi.\r\n',
            ),
          ),
      {...flags},
      ++highestModSeq,
      at,
    );
    messages.add(message);
    return message;
  }

  void remove(int uid) {
    messages.removeWhere((m) => m.uid == uid);
    highestModSeq++;
  }

  void setFlags(int uid, Set<String> flags) {
    final m = messages.firstWhere((m) => m.uid == uid);
    m.flags = {...flags};
    m.modSeq = ++highestModSeq;
  }
}

/// A small in-memory IMAP server over implicit TLS with real UIDs, enough
/// for folder syncs (LIST, STATUS, SELECT, UID SEARCH/FETCH/STORE/EXPUNGE/
/// MOVE, APPEND, CREATE), optionally with CONDSTORE. It records every
/// command and counts logins, so tests can check how much a sync does.
final class FakeImap {
  FakeImap._(this._server, this.condstore);

  static Future<FakeImap> start({bool condstore = false}) async {
    final context = SecurityContext()
      ..useCertificateChain('${_certs.path}/mail.crt')
      ..usePrivateKey('${_certs.path}/mail.key');
    final fake = FakeImap._(
      await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context),
      condstore,
    );
    fake._server.listen(fake._session, onError: (Object _) {});
    return fake;
  }

  /// Why tests with it are skipped, or null.
  static String? get skipReason => fakeServersSkipReason;

  final SecureServerSocket _server;
  final bool condstore;

  final folders = <String, FakeFolder>{'INBOX': FakeFolder()};

  /// Commands received (without tags, logins redacted), in order.
  final commands = <String>[];

  /// Successful logins (one per connection).
  int logins = 0;

  /// Open connections.
  int open = 0;

  /// Commands since [mark] whose name starts with [prefix].
  List<String> since(int mark, String prefix) => [
    for (final c in commands.skip(mark))
      if (c.toUpperCase().startsWith(prefix.toUpperCase())) c,
  ];

  MailConnector connector() => DefaultMailConnector(
    const _AnyPassword(),
    tls: TlsSettings.trustOnly(File('${_certs.path}/ca.crt').readAsBytesSync()),
    useQresync: false,
    endpointFor: (s) => ServerEndpoint(
      'mail.citusmail.test',
      _server.port,
      ConnectionSecurity.implicitTls,
      connectAddress: '127.0.0.1',
    ),
  );

  /// An account for this server in [store], with its folders listed.
  Account addAccount(MailStore store) {
    final account = store.accounts.add(
      NewAccount(
        email: 'alice@citusmail.test',
        username: 'alice@citusmail.test',
        imap: ServerSettings(
          host: 'mail.citusmail.test',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'mail.citusmail.test',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    return account;
  }

  Future<void> close() => _server.close();

  String get _capabilities =>
      'IMAP4rev1 AUTH=PLAIN SASL-IR LITERAL+ UIDPLUS MOVE SPECIAL-USE '
      'LIST-EXTENDED${condstore ? ' CONDSTORE' : ''}';

  void _session(Socket socket) {
    open++;
    socket.add(ascii.encode('* OK [CAPABILITY $_capabilities] fake\r\n'));
    var buffer = <int>[];
    FakeFolder? selected;
    ({String tag, String line, int length})? literal;

    void send(String text) => socket.add(latin1.encode(text));

    String reply(String tag, String line) {
      final words = _tokens(line);
      var command = words.first.toUpperCase();
      if (command == 'UID') command = 'UID ${words[1].toUpperCase()}';
      commands.add(
        command == 'AUTHENTICATE' || command == 'LOGIN' ? command : line,
      );
      switch (command) {
        case 'CAPABILITY':
          return '* CAPABILITY $_capabilities\r\n$tag OK done\r\n';
        case 'AUTHENTICATE' || 'LOGIN':
          logins++;
          return '$tag OK done\r\n';
        case 'NOOP' || 'ENABLE':
          return '$tag OK done\r\n';
        case 'LIST':
          return '${[for (final MapEntry(key: name, value: f) in folders.entries) '* LIST (\\HasNoChildren${f.specialUse == null ? '' : ' \\${f.specialUse}'}) "/" "$name"\r\n'].join()}'
              '$tag OK done\r\n';
        case 'CREATE':
          folders.putIfAbsent(words[1], FakeFolder.new);
          return '$tag OK done\r\n';
        case 'STATUS':
          final folder = folders[words[1]];
          if (folder == null) return '$tag NO [NONEXISTENT] no such folder\r\n';
          return '* STATUS "${words[1]}" (MESSAGES ${folder.messages.length} '
              'UIDNEXT ${folder.uidNext} UIDVALIDITY ${folder.uidValidity} '
              'UNSEEN 0)\r\n$tag OK done\r\n';
        case 'SELECT' || 'EXAMINE':
          final folder = selected = folders[words[1]];
          if (folder == null) return '$tag NO [NONEXISTENT] no such folder\r\n';
          return '* ${folder.messages.length} EXISTS\r\n'
              '* OK [UIDVALIDITY ${folder.uidValidity}] ok\r\n'
              '* OK [UIDNEXT ${folder.uidNext}] ok\r\n'
              '${condstore ? '* OK [HIGHESTMODSEQ ${folder.highestModSeq}] ok\r\n' : ''}'
              '$tag OK [READ-WRITE] done\r\n';
        case 'UID SEARCH':
          final folder = selected!;
          final found = [
            for (final m in folder.messages)
              if (_matches(m, folder, words.sublist(2))) m.uid,
          ];
          return '* SEARCH${found.map((n) => ' $n').join()}\r\n'
              '$tag OK done\r\n';
        case 'UID FETCH':
          final folder = selected!;
          final set = _set(words[2], folder);
          final changedSince = RegExp(r'CHANGEDSINCE (\d+)')
              .firstMatch(line)
              ?.group(1);
          final out = StringBuffer();
          for (final m in folder.messages) {
            if (!set(m.uid)) continue;
            if (changedSince != null && m.modSeq <= int.parse(changedSince)) {
              continue;
            }
            out.write(_fetch(m, line, folder));
          }
          return '$out$tag OK done\r\n';
        case 'UID STORE':
          final folder = selected!;
          final set = _set(words[2], folder);
          final flags = {
            for (final w in words.skip(4)) w.replaceAll(RegExp('[()]'), ''),
          }..remove('');
          for (final m in folder.messages.where((m) => set(m.uid))) {
            final mode = words[3].toUpperCase();
            m.flags = mode.startsWith('+')
                ? {...m.flags, ...flags}
                : mode.startsWith('-')
                ? m.flags.difference(flags)
                : flags;
            m.modSeq = ++folder.highestModSeq;
          }
          return '$tag OK done\r\n';
        case 'UID EXPUNGE':
          final folder = selected!;
          final set = _set(words[2], folder);
          folder.messages.removeWhere(
            (m) => set(m.uid) && m.flags.contains(r'\Deleted'),
          );
          folder.highestModSeq++;
          return '$tag OK done\r\n';
        case 'UID MOVE':
          final folder = selected!;
          final target = folders[words[3]];
          if (target == null) return '$tag NO [TRYCREATE] no such folder\r\n';
          final set = _set(words[2], folder);
          final moving = folder.messages.where((m) => set(m.uid)).toList();
          final to = [
            for (final m in moving)
              target
                  .add(raw: m.raw, flags: m.flags, date: m.date, messageId: '')
                  .uid,
          ];
          for (final m in moving) {
            folder.remove(m.uid);
          }
          return '* OK [COPYUID ${target.uidValidity} '
              '${moving.map((m) => m.uid).join(',')} ${to.join(',')}] moved\r\n'
              '$tag OK done\r\n';
        case 'LOGOUT':
          return '* BYE bye\r\n$tag OK done\r\n';
        default:
          return '$tag BAD unknown\r\n';
      }
    }

    void append(String tag, String line, Uint8List message) {
      final words = _tokens(line);
      commands.add('APPEND ${words[1]}');
      final folder = folders.putIfAbsent(words[1], FakeFolder.new);
      final flags = {
        for (final w in words.skip(2))
          if (w.startsWith('(') || w.startsWith(r'\'))
            w.replaceAll(RegExp('[()]'), ''),
      }..remove('');
      final added = folder.add(raw: message, flags: flags, messageId: '');
      send('$tag OK [APPENDUID ${folder.uidValidity} ${added.uid}] done\r\n');
    }

    socket.listen(
      (data) {
        buffer.addAll(data);
        while (true) {
          if (literal case final pending?) {
            if (buffer.length < pending.length) return;
            final message = Uint8List.fromList(
              buffer.sublist(0, pending.length),
            );
            final end = buffer.indexOf(0x0A, pending.length);
            if (end < 0) return;
            buffer = buffer.sublist(end + 1);
            literal = null;
            append(pending.tag, pending.line, message);
            continue;
          }
          final end = buffer.indexOf(0x0A);
          if (end < 0) return;
          final line = latin1.decode(buffer.sublist(0, end)).trimRight();
          buffer = buffer.sublist(end + 1);
          final space = line.indexOf(' ');
          if (space < 0) continue;
          final tag = line.substring(0, space);
          final rest = line.substring(space + 1);
          final size = RegExp(r'\{(\d+)\+?\}$').firstMatch(rest);
          if (size != null) {
            literal = (
              tag: tag,
              line: rest.substring(0, size.start).trimRight(),
              length: int.parse(size.group(1)!),
            );
            if (!size.group(0)!.contains('+')) send('+ go ahead\r\n');
            continue;
          }
          send(reply(tag, rest));
        }
      },
      onError: (_) {},
      onDone: () {
        open--;
        socket.destroy();
      },
    );
  }

  /// Words of a command line; quoted strings unquoted, lists kept apart
  /// only by their parentheses.
  static List<String> _tokens(String line) => [
    for (final m in RegExp(r'"((?:[^"\\]|\\.)*)"|\S+').allMatches(line))
      m.group(1) ?? m.group(0)!,
  ];

  static bool Function(int uid) _set(String text, FakeFolder folder) {
    final highest = folder.messages.isEmpty ? 0 : folder.messages.last.uid;
    final ranges = [
      for (final part in text.split(','))
        if (part.split(':') case [final a, final b])
          (_n(a, highest), _n(b, highest))
        else
          (_n(part, highest), _n(part, highest)),
    ];
    return (uid) => ranges.any(
      (r) =>
          uid >= (r.$1 < r.$2 ? r.$1 : r.$2) &&
          uid <= (r.$1 < r.$2 ? r.$2 : r.$1),
    );
  }

  static int _n(String s, int highest) => s == '*' ? highest : int.parse(s);

  static bool _matches(FakeMessage m, FakeFolder folder, List<String> words) {
    for (var i = 0; i < words.length; i++) {
      final word = words[i].replaceAll(RegExp('[()]'), '').toUpperCase();
      switch (word) {
        case 'ALL' || '':
          break;
        case 'UID':
          if (!_set(words[++i], folder)(m.uid)) return false;
        case 'SINCE':
          i++; // the fake keeps every date
        case 'HEADER':
          final name = words[++i].toLowerCase();
          final value = words[++i].toLowerCase();
          final head = latin1.decode(m.raw).split('\r\n\r\n').first;
          final hit = head
              .split('\r\n')
              .any(
                (l) =>
                    l.toLowerCase().startsWith('$name:') &&
                    l.toLowerCase().contains(value),
              );
          if (!hit) return false;
        default:
          break;
      }
    }
    return true;
  }

  String _fetch(FakeMessage m, String line, FakeFolder folder) {
    final items = <String>['UID ${m.uid}'];
    final upper = line.toUpperCase();
    if (upper.contains('FLAGS')) items.add('FLAGS (${m.flags.join(' ')})');
    if (upper.contains('MODSEQ') && condstore) {
      items.add('MODSEQ (${m.modSeq})');
    }
    if (upper.contains('INTERNALDATE')) {
      items.add('INTERNALDATE "${_date(m.date)}"');
    }
    if (upper.contains('RFC822.SIZE')) items.add('RFC822.SIZE ${m.raw.length}');
    if (upper.contains('ENVELOPE')) items.add('ENVELOPE ${_envelope(m)}');
    var body = '';
    if (upper.contains('BODY.PEEK[]')) {
      final raw = latin1.decode(m.raw);
      body = ' BODY[] {${m.raw.length}}\r\n$raw';
    }
    final seq = folder.messages.indexOf(m) + 1;
    return '* $seq FETCH (${items.join(' ')}$body)\r\n';
  }

  static String _envelope(FakeMessage m) {
    final head = latin1.decode(m.raw).split('\r\n\r\n').first.split('\r\n');
    String? header(String name) => head
        .where((l) => l.toLowerCase().startsWith('${name.toLowerCase()}:'))
        .map((l) => l.substring(name.length + 1).trim())
        .firstOrNull;
    String q(String? s) => s == null ? 'NIL' : '"${s.replaceAll('"', '')}"';
    String address(String? s) {
      if (s == null || !s.contains('@')) return 'NIL';
      final clean = s.replaceAll(RegExp('.*<|>.*'), '');
      final at = clean.indexOf('@');
      return '((NIL NIL ${q(clean.substring(0, at))} '
          '${q(clean.substring(at + 1))}))';
    }

    final from = address(header('From'));
    return '(NIL ${q(header('Subject'))} $from $from $from '
        '${address(header('To'))} NIL NIL NIL ${q(header('Message-ID'))})';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _date(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}-${_months[d.month - 1]}-${d.year} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)} +0000';
  }
}

final class _AnyPassword implements CredentialProvider {
  const _AnyPassword();

  @override
  Future<String> passwordFor(Account account) async => 'test-password';
}
