// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../net/mail_exception.dart';
import '../net/mail_socket.dart';
import '../net/server_endpoint.dart';
import 'imap_command.dart';
import 'imap_requests.dart';
import 'imap_response.dart';
import 'imap_response_reader.dart';
import 'imap_results.dart';
import 'imap_value.dart';
import 'sequence_set.dart';

/// Something the server reported about the selected folder without being
/// asked (new mail, deletions, flag changes) or a server notice.
sealed class ImapEvent {
  const ImapEvent();
}

/// The folder now has [count] messages.
final class ImapExistsEvent extends ImapEvent {
  const ImapExistsEvent(this.count);
  final int count;
}

/// The message at [sequence] was removed (later numbers shift down by one).
final class ImapExpungeEvent extends ImapEvent {
  const ImapExpungeEvent(this.sequence);
  final int sequence;
}

/// Messages with these UIDs were removed (QRESYNC).
final class ImapVanishedEvent extends ImapEvent {
  const ImapVanishedEvent(this.uids);
  final SequenceSet uids;
}

/// A message's flags (or other data) changed.
final class ImapMessageChangedEvent extends ImapEvent {
  const ImapMessageChangedEvent(this.message);
  final FetchedMessage message;
}

/// The server sent an [ALERT] the user must see.
final class ImapAlertEvent extends ImapEvent {
  const ImapAlertEvent(this.text);
  final String text;
}

/// Timeouts for an IMAP connection.
final class ImapTimeouts {
  const ImapTimeouts({
    this.connect = const Duration(seconds: 30),
    this.command = const Duration(seconds: 60),
    this.idle = const Duration(minutes: 25),
  });

  final Duration connect;

  /// Longest wait for any single reply line.
  final Duration command;

  /// Longest IDLE before it is renewed. RFC 9051 asks clients to re-issue
  /// IDLE at least every 29 minutes; 25 leaves margin for slow networks.
  final Duration idle;
}

/// Result of a UID FETCH: the messages, plus UIDs reported as removed when
/// VANISHED was requested.
final class FetchResult {
  FetchResult(List<FetchedMessage> messages, this.vanished)
    : messages = List.unmodifiable(messages);

  final List<FetchedMessage> messages;
  final SequenceSet? vanished;
}

/// Result of a UID STORE.
final class StoreResult {
  StoreResult(this.notModified, List<FetchedMessage> updated)
    : updated = List.unmodifiable(updated);

  /// With UNCHANGEDSINCE: UIDs not changed because they changed on the
  /// server in the meantime (RFC 7162 [MODIFIED]).
  final SequenceSet? notModified;

  /// Updated flags reported by the server.
  final List<FetchedMessage> updated;
}

/// Result of moving or copying messages.
final class TransferResult {
  const TransferResult(this.mapping, {this.originalsMarkedDeleted = false});

  /// Old and new UIDs, when the server supports UIDPLUS.
  final UidMapping? mapping;

  /// True when a move was emulated (COPY + \Deleted) on a server without
  /// MOVE or UIDPLUS: the originals are marked deleted but still present,
  /// because expunging without UIDPLUS could also remove messages that
  /// another device had only marked.
  final bool originalsMarkedDeleted;
}

/// An IMAP4rev1 / IMAP4rev2 client (RFC 3501, RFC 9051) for one
/// connection.
///
/// Commands run one at a time in the order they are called. If a command
/// fails because of a timeout, a protocol error or a lost connection, the
/// connection is closed and every later call fails: the caller reconnects.
/// A server rejecting a command (NO/BAD) does not close the connection.
final class ImapClient {
  ImapClient._(this._socket, this._reader, this.endpoint, this.timeouts);

  final MailSocket _socket;
  final ImapResponseReader _reader;
  final ServerEndpoint endpoint;
  final ImapTimeouts timeouts;

  // Asynchronous delivery: a listener's error can never disturb the
  // protocol reader.
  final _events = StreamController<ImapEvent>.broadcast();
  ImapCapabilities _capabilities = ImapCapabilities.none;
  final Set<String> _enabled = {};
  bool _authenticated = false;
  SelectedMailbox? _selected;
  int _tagCounter = 0;
  Future<void> _queue = Future.value();
  MailException? _broken;

  /// Unsolicited server events for the selected folder.
  Stream<ImapEvent> get events => _events.stream;

  ImapCapabilities get capabilities => _capabilities;

  /// Extensions turned on with ENABLE (e.g. CONDSTORE, QRESYNC).
  Set<String> get enabled => Set.unmodifiable(_enabled);

  bool get isAuthenticated => _authenticated;

  /// The selected folder, if any.
  SelectedMailbox? get selected => _selected;

  /// Whether the connection can still be used.
  bool get isUsable => _broken == null;

  /// Connects, reads the greeting and, for [ConnectionSecurity.startTls],
  /// upgrades to TLS. Returns only once the connection is encrypted.
  static Future<ImapClient> connect(
    ServerEndpoint endpoint, {
    TlsSettings tls = const TlsSettings(),
    ImapTimeouts timeouts = const ImapTimeouts(),
    ImapResponseLimits limits = const ImapResponseLimits(),
  }) async {
    final socket = await MailSocket.connect(
      endpoint,
      tls: tls,
      timeout: timeouts.connect,
    );
    final client = ImapClient._(
      socket,
      ImapResponseReader(socket, limits: limits),
      endpoint,
      timeouts,
    );
    try {
      await client._greet();
      return client;
    } on Object {
      await socket.close();
      rethrow;
    }
  }

  Future<void> _greet() async {
    final greeting = await _reader.next(timeout: timeouts.command);
    if (greeting is! ImapUntaggedStatus) {
      throw const MailProtocolException(
        'the server did not send an IMAP greeting',
      );
    }
    switch (greeting.status) {
      case ImapStatus.bye:
        throw MailConnectionException(
          'the server refused the connection: ${greeting.text}',
        );
      case ImapStatus.preauth when !_socket.isSecure:
        // A plain-text PREAUTH would skip STARTTLS entirely (a known way to
        // strip encryption). Refuse it.
        throw const MailSecurityException(
          'the server tried to skip encryption (PREAUTH before TLS)',
        );
      case ImapStatus.preauth:
        _authenticated = true;
      case ImapStatus.ok:
        break;
      default:
        throw MailConnectionException('unexpected greeting: ${greeting.text}');
    }
    final code = greeting.code;
    if (code != null && code.name == 'CAPABILITY') {
      _capabilities = ImapCapabilities.fromValues(code.arguments);
    }

    if (endpoint.security == ConnectionSecurity.startTls) {
      if (_capabilities.names.isEmpty) await refreshCapabilities();
      if (!_capabilities.has('STARTTLS')) {
        throw const MailSecurityException(
          'the server does not offer STARTTLS; refusing to continue unencrypted',
        );
      }
      await _run(ImapCommand('STARTTLS'));
      await _socket.startTls();
      // Anything learned before TLS may have been forged: start over.
      _capabilities = ImapCapabilities.none;
    }
    if (_capabilities.names.isEmpty) await refreshCapabilities();
  }

  /// Asks the server for its capabilities again.
  Future<ImapCapabilities> refreshCapabilities() async {
    await _run(ImapCommand('CAPABILITY'));
    return _capabilities;
  }

  /// Logs in. Uses AUTHENTICATE PLAIN when offered, otherwise LOGIN.
  ///
  /// Refuses to run on a connection that is not encrypted, so a password
  /// can never be sent in plain text.
  Future<void> login(String username, String password) async {
    if (!_socket.isSecure) {
      throw const MailSecurityException(
        'refusing to send credentials over an unencrypted connection',
      );
    }
    if (_capabilities.has('LOGINDISABLED')) {
      throw ImapAuthenticationException(
        'the server does not allow login on this connection',
      );
    }
    try {
      if (_capabilities.supportsAuth('PLAIN')) {
        final token = base64.encode(
          utf8.encode('\u0000$username\u0000$password'),
        );
        final command = ImapCommand('AUTHENTICATE')..atom('PLAIN');
        command.redacted = 'AUTHENTICATE PLAIN [redacted]';
        if (_capabilities.has('SASL-IR')) {
          command.atom(token);
          await _run(command);
        } else {
          await _run(command, saslResponse: token);
        }
      } else {
        final command = ImapCommand('LOGIN')
          ..string(username)
          ..string(password);
        command.redacted = 'LOGIN [redacted]';
        await _run(command);
      }
    } on ImapCommandException catch (e) {
      throw ImapAuthenticationException(
        'login refused by the server: ${e.serverText}',
        code: e.code,
      );
    }
    _authenticated = true;
    // Capabilities often change after login (RFC 9051 6.2.3).
    await refreshCapabilities();
  }

  /// Turns on extensions such as CONDSTORE and QRESYNC (RFC 5161).
  /// Returns those the server actually enabled.
  Future<Set<String>> enable(List<String> extensions) async {
    if (!_capabilities.has('ENABLE')) return const {};
    final wanted = extensions.where(_capabilities.has).toList();
    if (wanted.isEmpty) return const {};
    final command = ImapCommand('ENABLE');
    for (final e in wanted) {
      command.atom(e);
    }
    await _run(
      command,
      onData: (data) {
        if (data.keyword != 'ENABLED') return false;
        _enabled.addAll(
          data.values.map((v) => v.asText?.toUpperCase()).whereType<String>(),
        );
        return true;
      },
    );
    return enabled;
  }

  /// All folders, with special-use attributes when the server has them.
  Future<List<ImapMailboxInfo>> listMailboxes() async {
    final command = ImapCommand('LIST')
      ..string('')
      ..string('*');
    if (_capabilities.has('SPECIAL-USE') &&
        _capabilities.has('LIST-EXTENDED')) {
      command.raw('RETURN (SPECIAL-USE)');
    }
    final result = <ImapMailboxInfo>[];
    await _run(
      command,
      onData: (data) {
        if (data.keyword != 'LIST') return false;
        final info = ImapMailboxInfo.fromResponse(data);
        if (info != null) result.add(info);
        return true;
      },
    );
    return result;
  }

  /// Folder counters without selecting it.
  Future<MailboxStatus> status(
    String encodedName, {
    bool highestModSeq = false,
  }) async {
    final items = [
      'MESSAGES',
      'UIDNEXT',
      'UIDVALIDITY',
      'UNSEEN',
      if (highestModSeq) 'HIGHESTMODSEQ',
    ];
    final command = ImapCommand('STATUS')
      ..string(encodedName)
      ..raw('(${items.join(' ')})');
    MailboxStatus? status;
    await _run(
      command,
      onData: (data) {
        if (data.keyword != 'STATUS' || data.values.length < 2) return false;
        status = MailboxStatus.fromValues(data.values[1].asList ?? const []);
        return true;
      },
    );
    return status ?? const MailboxStatus();
  }

  /// Opens a folder. [readOnly] uses EXAMINE, which never changes flags.
  /// With [qresync] (after `enable(['QRESYNC'])`) the server also reports
  /// what changed since the cached state.
  Future<SelectedMailbox> select(
    String encodedName, {
    bool readOnly = false,
    QresyncParameters? qresync,
  }) async {
    final command = ImapCommand(readOnly ? 'EXAMINE' : 'SELECT')
      ..string(encodedName);
    if (qresync != null && _enabled.contains('QRESYNC')) {
      final known = qresync.knownUids;
      command.raw(
        '(QRESYNC (${qresync.uidValidity} ${qresync.highestModSeq}'
        '${known == null ? '' : ' $known'}))',
      );
    } else if (_capabilities.has('CONDSTORE') &&
        !_enabled.contains('QRESYNC')) {
      command.raw('(CONDSTORE)');
    }

    var exists = 0;
    int? uidValidity, uidNext, highestModSeq;
    var flags = <String>{}, permanentFlags = <String>{};
    SequenceSet? vanished;
    final changed = <FetchedMessage>[];

    _selected = null;
    final tagged = await _run(
      command,
      onData: (data) {
        switch (data.keyword) {
          case 'EXISTS':
            exists = data.number ?? exists;
          case 'FLAGS':
            flags = _flagSet(data.values.firstOrNull);
          case 'VANISHED':
            vanished = _vanished(data);
          case 'FETCH':
            changed.add(FetchedMessage.fromResponse(data));
          case 'RECENT':
            break;
          default:
            return false;
        }
        return true;
      },
      onStatusCode: (code) {
        switch (code.name) {
          case 'UIDVALIDITY':
            uidValidity = code.number;
          case 'UIDNEXT':
            uidNext = code.number;
          case 'HIGHESTMODSEQ':
            highestModSeq = code.number;
          case 'NOMODSEQ':
            highestModSeq = null;
          case 'PERMANENTFLAGS':
            permanentFlags = _flagSet(code.arguments.firstOrNull);
        }
      },
    );
    final validity = uidValidity;
    if (validity == null) {
      throw const MailProtocolException(
        'the server did not report UIDVALIDITY',
      );
    }
    final selected = SelectedMailbox(
      name: encodedName,
      readOnly: readOnly || tagged.code?.name == 'READ-ONLY',
      exists: exists,
      uidValidity: validity,
      uidNext: uidNext,
      highestModSeq: highestModSeq,
      flags: flags,
      permanentFlags: permanentFlags,
      vanished: vanished,
      changedMessages: changed,
    );
    _selected = selected;
    return selected;
  }

  /// Fetches messages by UID. With [changedSince] (CONDSTORE) only
  /// messages changed after that mod-sequence are returned; adding
  /// [vanished] (QRESYNC) also reports removed UIDs.
  Future<FetchResult> uidFetch(
    SequenceSet uids,
    FetchItems items, {
    int? changedSince,
    bool vanished = false,
  }) async {
    _requireSelected();
    final command = ImapCommand('UID')
      ..atom('FETCH')
      ..sequenceSet(uids)
      ..raw(items.toSyntax());
    if (changedSince != null) {
      final reportVanished = vanished && _enabled.contains('QRESYNC');
      command.raw(
        '(CHANGEDSINCE $changedSince${reportVanished ? ' VANISHED' : ''})',
      );
    }
    final messages = <FetchedMessage>[];
    SequenceSet? removed;
    await _run(
      command,
      onData: (data) {
        if (data.keyword == 'FETCH') {
          final message = FetchedMessage.fromResponse(data);
          final uid = message.uid;
          if (uid != null && uids.contains(uid)) {
            messages.add(message);
          } else {
            _events.add(ImapMessageChangedEvent(message)); // unrelated update
          }
          return true;
        }
        if (data.keyword == 'VANISHED') {
          removed = _vanished(data);
          return true;
        }
        return false;
      },
    );
    return FetchResult(messages, removed);
  }

  /// UIDs matching [criteria] in the selected folder.
  Future<SearchResult> uidSearch(SearchCriteria criteria) async {
    _requireSelected();
    final command = ImapCommand('UID')..atom('SEARCH');
    criteria.applyTo(command);
    final found = <int>[];
    int? modSeq;
    await _run(
      command,
      onData: (data) {
        if (data.keyword != 'SEARCH') return false;
        for (final value in data.values) {
          final n = value.asNumber;
          if (n != null && n > 0) {
            found.add(n);
          } else if (value is ImapList &&
              value.length == 2 &&
              value[0].asText?.toUpperCase() == 'MODSEQ') {
            modSeq = value[1].asNumber;
          }
        }
        return true;
      },
    );
    return SearchResult(SequenceSet.of(found), highestModSeq: modSeq);
  }

  /// Changes flags. With [unchangedSince] (CONDSTORE) the change is only
  /// applied to messages not modified on the server since then, which
  /// prevents overwriting another device's newer change.
  Future<StoreResult> uidStore(
    SequenceSet uids,
    FlagChange change,
    Set<String> flags, {
    int? unchangedSince,
    bool silent = true,
  }) async {
    _requireSelected();
    final command = ImapCommand('UID')
      ..atom('STORE')
      ..sequenceSet(uids);
    if (unchangedSince != null) command.raw('(UNCHANGEDSINCE $unchangedSince)');
    final verb = switch (change) {
      FlagChange.add => '+FLAGS',
      FlagChange.remove => '-FLAGS',
      FlagChange.replace => 'FLAGS',
    };
    command
      ..atom(silent ? '$verb.SILENT' : verb)
      ..openList();
    for (final flag in flags) {
      command.flag(flag);
    }
    command.closeList();
    final updated = <FetchedMessage>[];
    final tagged = await _run(
      command,
      onData: (data) {
        if (data.keyword != 'FETCH') return false;
        updated.add(FetchedMessage.fromResponse(data));
        return true;
      },
    );
    final code = tagged.code;
    final notModified = code?.name == 'MODIFIED'
        ? SequenceSet.tryParse(code!.arguments.firstOrNull?.asText ?? '')
        : null;
    return StoreResult(notModified, updated);
  }

  /// Copies messages to another folder.
  Future<TransferResult> uidCopy(
    SequenceSet uids,
    String targetEncodedName,
  ) async {
    _requireSelected();
    final tagged = await _run(
      ImapCommand('UID')
        ..atom('COPY')
        ..sequenceSet(uids)
        ..string(targetEncodedName),
    );
    return TransferResult(UidMapping.fromCode(tagged.code));
  }

  /// Moves messages to another folder: MOVE (RFC 6851) when available,
  /// otherwise COPY, mark \Deleted, and UID EXPUNGE (only with UIDPLUS).
  Future<TransferResult> uidMove(
    SequenceSet uids,
    String targetEncodedName,
  ) async {
    _requireSelected();
    if (_capabilities.has('MOVE')) {
      UidMapping? mapping;
      final tagged = await _run(
        ImapCommand('UID')
          ..atom('MOVE')
          ..sequenceSet(uids)
          ..string(targetEncodedName),
        onStatusCode: (code) => mapping ??= UidMapping.fromCode(code),
      );
      return TransferResult(mapping ?? UidMapping.fromCode(tagged.code));
    }
    final copied = await uidCopy(uids, targetEncodedName);
    await uidStore(uids, FlagChange.add, {r'\Deleted'});
    if (_capabilities.has('UIDPLUS')) {
      await uidExpunge(uids);
      return copied;
    }
    return TransferResult(copied.mapping, originalsMarkedDeleted: true);
  }

  /// Permanently removes messages that have \Deleted, limited to [uids]
  /// (UIDPLUS). There is deliberately no plain EXPUNGE: it would also
  /// remove messages other devices had only marked.
  Future<void> uidExpunge(SequenceSet uids) async {
    _requireSelected();
    if (!_capabilities.has('UIDPLUS')) {
      throw const MailProtocolException(
        'UID EXPUNGE needs the UIDPLUS extension',
      );
    }
    await _run(
      ImapCommand('UID')
        ..atom('EXPUNGE')
        ..sequenceSet(uids),
    );
  }

  /// Adds a message to a folder (for example, a sent message to Sent).
  Future<UidMapping?> append(
    String targetEncodedName,
    Uint8List message, {
    Set<String> flags = const {},
    DateTime? internalDate,
  }) async {
    final command = ImapCommand('APPEND')..string(targetEncodedName);
    if (flags.isNotEmpty) {
      command.openList();
      for (final flag in flags) {
        command.flag(flag);
      }
      command.closeList();
    }
    if (internalDate != null) command.raw('"${_internalDate(internalDate)}"');
    command.literal(message);
    final tagged = await _run(command);
    return UidMapping.fromCode(tagged.code);
  }

  /// Creates a folder. [name] is the readable name (it is encoded here);
  /// use the server's delimiter for nesting. Succeeds quietly if the
  /// folder already exists.
  Future<void> create(String name) async {
    try {
      await _run(ImapCommand('CREATE')..mailbox(name));
    } on ImapCommandException catch (e) {
      if (e.code?.name != 'ALREADYEXISTS') rethrow;
    }
  }

  /// Deletes a folder (and the messages in it) on the server. Succeeds
  /// quietly if it does not exist.
  Future<void> deleteMailbox(String encodedName) async {
    if (encodedName.toUpperCase() == 'INBOX') {
      throw ArgumentError('INBOX cannot be deleted');
    }
    try {
      await _run(ImapCommand('DELETE')..string(encodedName));
    } on ImapCommandException catch (e) {
      if (e.code?.name != 'NONEXISTENT') rethrow;
    }
    if (_selected?.name == encodedName) _selected = null;
  }

  /// Waits for server events (IDLE, RFC 2177) until [until] completes or
  /// [ImapTimeouts.idle] passes, whichever is first. Events arrive on
  /// [events]. Call again to keep waiting.
  Future<void> idle({Future<void>? until}) async {
    _requireSelected();
    if (!_capabilities.has('IDLE')) {
      throw const MailProtocolException('the server does not support IDLE');
    }
    await _serialized(() async {
      final tag = _nextTag();
      await _socket.write(ascii.encode('$tag IDLE\r\n'));
      // Wait for "+ idling".
      while (true) {
        final response = await _reader.next(timeout: timeouts.command);
        if (response is ImapContinuation) break;
        if (response is ImapTaggedResponse && response.tag == tag) {
          _checkTagged(response, 'IDLE');
          return; // server ended IDLE at once
        }
        _handleUnsolicited(response);
      }
      var doneSent = false;
      Future<void> sendDone() async {
        if (doneSent || !isUsable) return;
        doneSent = true;
        await _socket.write(ascii.encode('DONE\r\n'));
      }

      final stopTimer = Timer(timeouts.idle, () => unawaited(sendDone()));
      // Stop on [until] whether it completes or fails.
      unawaited(
        until?.then((_) => sendDone(), onError: (Object _) => sendDone()),
      );
      try {
        while (true) {
          final response = await _reader.next(
            timeout: timeouts.idle + timeouts.command,
          );
          if (response is ImapTaggedResponse && response.tag == tag) {
            _checkTagged(response, 'IDLE');
            return;
          }
          _handleUnsolicited(response);
        }
      } finally {
        stopTimer.cancel();
        doneSent = true; // never send DONE after IDLE has ended
      }
    });
  }

  /// Asks the server for pending updates (and keeps the connection alive).
  Future<void> noop() => _run(ImapCommand('NOOP'));

  /// Logs out politely and closes the connection.
  Future<void> logout() async {
    try {
      if (isUsable) await _run(ImapCommand('LOGOUT'));
    } on MailException {
      // Closing anyway.
    } finally {
      await close();
    }
  }

  /// Closes the connection immediately.
  Future<void> close() async {
    _broken ??= const MailConnectionException('connection closed');
    await _socket.close();
    if (!_events.isClosed) await _events.close();
  }

  // ---------------------------------------------------------------------

  /// Runs one command and reads responses until its tagged completion.
  ///
  /// [onData] gets untagged data first and returns true if it used it;
  /// unused data becomes events. [onStatusCode] gets codes from untagged
  /// OK responses (e.g. [UIDVALIDITY]). [saslResponse] answers a single
  /// SASL continuation.
  Future<ImapTaggedResponse> _run(
    ImapCommand command, {
    bool Function(ImapUntaggedData data)? onData,
    void Function(ImapResponseCode code)? onStatusCode,
    String? saslResponse,
  }) {
    return _serialized(() async {
      final tag = _nextTag();
      final parts = command.build();
      final name = _commandName(parts);
      final line = StringBuffer('$tag ');

      for (final part in parts) {
        switch (part) {
          case TextPart(:final text):
            line.write(text);
          case LiteralPart(:final bytes):
            final nonSync =
                _capabilities.has('LITERAL+') ||
                (_capabilities.has('LITERAL-') && bytes.length <= 4096);
            line.write('{${bytes.length}${nonSync ? '+' : ''}}\r\n');
            await _socket.write(ascii.encode(line.toString()));
            line.clear();
            if (!nonSync) {
              await _awaitContinuation(tag, name, onData, onStatusCode);
            }
            await _socket.write(bytes);
        }
      }
      line.write('\r\n');
      await _socket.write(ascii.encode(line.toString()));

      var saslSent = false;
      while (true) {
        final response = await _reader.next(timeout: timeouts.command);
        switch (response) {
          case ImapTaggedResponse(tag: final t) when t == tag:
            _checkTagged(response, name);
            final code = response.code;
            if (code != null && code.name == 'CAPABILITY') {
              _capabilities = ImapCapabilities.fromValues(code.arguments);
            }
            return response;
          case ImapTaggedResponse():
            throw const MailProtocolException(
              'reply for an unknown command tag',
            );
          case ImapContinuation():
            if (saslResponse == null || saslSent) {
              throw const MailProtocolException(
                'unexpected continuation request',
              );
            }
            saslSent = true;
            await _socket.write(ascii.encode('$saslResponse\r\n'));
          case ImapUntaggedData():
            if (onData == null || !onData(response)) {
              _handleUnsolicited(response);
            }
          case ImapUntaggedStatus():
            final code = response.code;
            if (code != null && onStatusCode != null) onStatusCode(code);
            _handleUnsolicited(response);
        }
      }
    });
  }

  Future<void> _awaitContinuation(
    String tag,
    String name,
    bool Function(ImapUntaggedData)? onData,
    void Function(ImapResponseCode)? onStatusCode,
  ) async {
    while (true) {
      final response = await _reader.next(timeout: timeouts.command);
      switch (response) {
        case ImapContinuation():
          return;
        case ImapTaggedResponse(tag: final t) when t == tag:
          _checkTagged(
            response,
            name,
          ); // throws: the server refused the literal
          throw const MailProtocolException(
            'command ended before its data was sent',
          );
        case ImapTaggedResponse():
          throw const MailProtocolException('reply for an unknown command tag');
        case ImapUntaggedData():
          if (onData == null || !onData(response)) _handleUnsolicited(response);
        case ImapUntaggedStatus():
          final code = response.code;
          if (code != null && onStatusCode != null) onStatusCode(code);
          _handleUnsolicited(response);
      }
    }
  }

  /// Runs [action] after all earlier commands; a connection-level failure
  /// marks the client unusable and closes the socket.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) async {
      final broken = _broken;
      if (broken != null) throw broken;
      try {
        return await action();
      } on ImapCommandException {
        rethrow; // the server said no; the connection is still fine
      } on ImapAuthenticationException {
        rethrow;
      } on MailException catch (e) {
        _broken = e;
        await _socket.close();
        rethrow;
      }
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  void _checkTagged(ImapTaggedResponse response, String name) {
    if (response.status == ImapStatus.ok) return;
    throw ImapCommandException(
      name,
      response.status,
      response.code,
      response.text,
    );
  }

  void _handleUnsolicited(ImapResponse response) {
    switch (response) {
      case ImapUntaggedData(keyword: 'EXISTS', :final number?):
        _events.add(ImapExistsEvent(number));
      case ImapUntaggedData(keyword: 'EXPUNGE', :final number?):
        _events.add(ImapExpungeEvent(number));
      case ImapUntaggedData(keyword: 'VANISHED'):
        final set = _vanished(response);
        if (set != null) _events.add(ImapVanishedEvent(set));
      case ImapUntaggedData(keyword: 'FETCH'):
        _events.add(
          ImapMessageChangedEvent(FetchedMessage.fromResponse(response)),
        );
      case ImapUntaggedData(keyword: 'CAPABILITY'):
        _capabilities = ImapCapabilities.fromValues(response.values);
      case ImapUntaggedStatus(status: ImapStatus.bye):
        _broken ??= MailConnectionException(
          'the server closed the session: ${response.text}',
        );
      case ImapUntaggedStatus(:final code?) when code.name == 'ALERT':
        _events.add(ImapAlertEvent(response.text));
      default:
        break;
    }
  }

  void _requireSelected() {
    if (_selected == null) throw StateError('no folder selected');
  }

  String _nextTag() => 'F${++_tagCounter}';

  /// The command name for errors, e.g. `UID FETCH`; never its arguments.
  static String _commandName(List<CommandPart> parts) {
    final first = parts.first;
    if (first is! TextPart) return 'command';
    final words = first.text.split(' ');
    return words.first == 'UID' && words.length > 1
        ? 'UID ${words[1]}'
        : words.first;
  }

  static Set<String> _flagSet(ImapValue? value) =>
      value?.asList?.map((f) => f.asText).whereType<String>().toSet() ??
      <String>{};

  /// `* VANISHED [(EARLIER)] set`
  static SequenceSet? _vanished(ImapUntaggedData data) {
    final last = data.values.lastOrNull?.asText;
    return last == null ? null : SequenceSet.tryParse(last);
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

  /// `21-Oct-2026 12:30:00 +0000` (always UTC: no location hint).
  static String _internalDate(DateTime date) {
    final t = date.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}-${_months[t.month - 1]}-${t.year} ${two(t.hour)}:${two(t.minute)}:${two(t.second)} +0000';
  }
}
