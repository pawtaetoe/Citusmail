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
///
/// With [maxLoggedIn], it refuses a login like Gmail once that many
/// connections are logged in ("Too many simultaneous connections"). With
/// [idle], it has IDLE. [latency] delays every answer, so work on several
/// connections overlaps as it does with a real server.
///
/// With [gmail], it says it has Gmail's extensions (`X-GM-EXT-1`) and
/// answers `X-GM-RAW` searches: `in:inbox` (and sent, drafts, spam, trash)
/// is true when that folder has a message with the same Message-ID,
/// `is:starred` when it is flagged, other words when the message has them;
/// a leading `-` turns any of them around.
final class FakeImap {
  FakeImap._(this._server, this.condstore, this.gmail, this.idle);

  static Future<FakeImap> start({
    bool condstore = false,
    bool gmail = false,
    bool idle = false,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain('${_certs.path}/mail.crt')
      ..usePrivateKey('${_certs.path}/mail.key');
    final fake = FakeImap._(
      await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context),
      condstore,
      gmail,
      idle,
    );
    fake._server.listen(fake._session, onError: (Object _) {});
    return fake;
  }

  /// Why tests with it are skipped, or null.
  static String? get skipReason => fakeServersSkipReason;

  final SecureServerSocket _server;
  final bool condstore;
  final bool gmail;
  final bool idle;

  /// Logins refused once this many connections are logged in (Gmail
  /// allows about 15 per account); null for no limit.
  int? maxLoggedIn;

  /// How long each answer takes.
  Duration latency = Duration.zero;

  /// When it returns true for a command, the server drops the connection
  /// instead of answering (the network went away).
  bool Function(String command)? dropOn;

  /// Whether SINCE compares dates (by default every date matches).
  bool filterDates = false;

  final folders = <String, FakeFolder>{'INBOX': FakeFolder()};

  /// Commands received (without tags, logins redacted), in order.
  final commands = <String>[];

  /// Successful logins (one per connection).
  int logins = 0;

  /// Open connections.
  int open = 0;

  /// Connections logged in and not yet logged out or closed.
  int loggedIn = 0;

  /// The most connections logged in at once.
  int peakLoggedIn = 0;

  /// Connections in IDLE now.
  int inIdle = 0;

  /// Logins refused for [maxLoggedIn].
  int refused = 0;

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
  /// Several accounts can share the server, each with its own [email].
  Account addAccount(MailStore store, {String email = 'alice@citusmail.test'}) {
    final account = store.accounts.add(
      NewAccount(
        email: email,
        username: email,
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
      'LIST-EXTENDED${condstore ? ' CONDSTORE' : ''}'
      '${gmail ? ' X-GM-EXT-1' : ''}${idle ? ' IDLE' : ''}';

  void _session(Socket socket) {
    open++;
    socket.add(ascii.encode('* OK [CAPABILITY $_capabilities] fake\r\n'));
    var buffer = <int>[];
    FakeFolder? selected;
    ({String tag, String line, int length})? literal;
    var authenticated = false;
    String? idling;
    var answered = Future<void>.value();

    void logOut() {
      if (!authenticated) return;
      authenticated = false;
      loggedIn--;
    }

    var gone = false;
    void ended() {
      if (gone) return;
      gone = true;
      open--;
      if (idling != null) inIdle--;
      logOut();
      socket.destroy();
    }

    void send(String text) {
      void write() {
        try {
          socket.add(latin1.encode(text));
        } on Object {
          // The connection is gone.
        }
      }

      if (latency == Duration.zero) {
        write();
      } else {
        answered = answered.then((_) => Future<void>.delayed(latency, write));
      }
    }

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
          if (maxLoggedIn case final max? when loggedIn >= max) {
            refused++;
            return '$tag NO [ALERT] Too many simultaneous connections. '
                '(Failure)\r\n';
          }
          logins++;
          authenticated = true;
          loggedIn++;
          if (loggedIn > peakLoggedIn) peakLoggedIn = loggedIn;
          return '$tag OK done\r\n';
        case 'IDLE' when idle:
          idling = tag;
          inIdle++;
          return '+ idling\r\n';
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
          final keys = _searchTokens(
            line.replaceFirst(
              RegExp(r'^UID\s+SEARCH', caseSensitive: false),
              '',
            ),
          );
          final found = [
            for (final m in folder.messages)
              if (_matches(m, folder, keys)) m.uid,
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
          logOut();
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
          if (idling case final tag? when line.toUpperCase() == 'DONE') {
            idling = null;
            inIdle--;
            send('$tag OK idle done\r\n');
            continue;
          }
          if (dropOn?.call(line.substring(line.indexOf(' ') + 1)) ?? false) {
            ended();
            return;
          }
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
      onDone: ended,
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

  /// Search keys: quoted strings (unquoted), parentheses, and words.
  static List<String> _searchTokens(String text) => [
    for (final m in RegExp(
      r'"((?:[^"\\]|\\.)*)"|[()]|[^\s()]+',
    ).allMatches(text))
      m.group(1)?.replaceAllMapped(RegExp(r'\\(.)'), (e) => e.group(1)!) ??
          m.group(0)!,
  ];

  /// Whether [m] matches every key of [keys]. Keys the fake does not know
  /// match everything.
  bool _matches(FakeMessage m, FakeFolder folder, List<String> keys) {
    var i = 0;
    bool key() {
      final word = keys[i++];
      switch (word.toUpperCase()) {
        case '(':
          var all = true;
          while (i < keys.length && keys[i] != ')') {
            if (!key()) all = false;
          }
          i++;
          return all;
        case 'OR':
          final a = key();
          final b = key();
          return a || b;
        case 'NOT':
          return !key();
        case 'UID':
          return _set(keys[i++], folder)(m.uid);
        case 'SINCE':
          final since = _parseDate(keys[i++]);
          return !filterDates || !m.date.isBefore(since);
        case 'CHARSET' || 'MODSEQ':
          i++;
          return true;
        case 'FLAGGED':
          return m.flags.contains(r'\Flagged');
        case 'HEADER':
          final name = keys[i++].toLowerCase();
          final value = keys[i++].toLowerCase();
          return _header(m, name)?.toLowerCase().contains(value) ?? false;
        case 'SUBJECT' || 'FROM':
          final value = keys[i++].toLowerCase();
          final header = _header(m, word.toLowerCase());
          return header?.toLowerCase().contains(value) ?? false;
        case 'TEXT':
          final value = keys[i++].toLowerCase();
          return latin1.decode(m.raw).toLowerCase().contains(value);
        case 'X-GM-RAW' when gmail:
          return _gmailMatches(m, keys[i++]);
        default:
          return true;
      }
    }

    var all = true;
    while (i < keys.length) {
      if (!key()) all = false;
    }
    return all;
  }

  /// Gmail's search ([gmail]): see the class comment.
  bool _gmailMatches(FakeMessage m, String query) {
    final id = _header(m, 'message-id');
    bool inFolder(String label) {
      final name = switch (label) {
        'inbox' => 'INBOX',
        'sent' => _named('Sent'),
        'drafts' => _named('Drafts'),
        'spam' => _named('Junk'),
        'trash' => _named('Trash'),
        _ => null,
      };
      final folder = folders[name];
      return folder != null &&
          id != null &&
          folder.messages.any((o) => _header(o, 'message-id') == id);
    }

    final text = latin1.decode(m.raw).toLowerCase();
    for (final match in RegExp(r'-?"[^"]*"|\S+').allMatches(query)) {
      var term = match.group(0)!;
      final negated = term.startsWith('-');
      if (negated) term = term.substring(1);
      term = term.replaceAll('"', '').toLowerCase();
      final hit = term.startsWith('in:')
          ? inFolder(term.substring(3))
          : term == 'is:starred'
          ? m.flags.contains(r'\Flagged')
          : text.contains(term);
      if (hit == negated) return false;
    }
    return true;
  }

  /// The name of the folder with [specialUse], if any.
  String? _named(String specialUse) => folders.entries
      .where((e) => e.value.specialUse == specialUse)
      .map((e) => e.key)
      .firstOrNull;

  static String? _header(FakeMessage m, String name) {
    final head = latin1.decode(m.raw).split('\r\n\r\n').first;
    for (final line in head.split('\r\n')) {
      if (line.toLowerCase().startsWith('$name:')) {
        return line.substring(name.length + 1).trim();
      }
    }
    return null;
  }

  static DateTime _parseDate(String text) {
    final [day, month, year] = text.split('-');
    return DateTime.utc(
      int.parse(year),
      _months.indexOf(month) + 1,
      int.parse(day),
    );
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
    final fields = RegExp(
      r'BODY\.PEEK\[HEADER\.FIELDS \(([^)]*)\)\]',
      caseSensitive: false,
    ).firstMatch(line);
    if (fields != null) {
      final names = fields.group(1)!.toLowerCase().split(' ');
      final head = latin1.decode(m.raw).split('\r\n\r\n').first;
      final kept = [
        for (final l in head.split('\r\n'))
          if (names.any((n) => l.toLowerCase().startsWith('$n:'))) '$l\r\n',
      ].join();
      final section = '$kept\r\n';
      body +=
          ' BODY[HEADER.FIELDS (${fields.group(1)})] {${section.length}}'
          '\r\n$section';
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
