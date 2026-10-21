// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import '../net/line_source.dart';
import '../net/mail_exception.dart';
import 'imap_response.dart';
import 'imap_value.dart';

/// Limits on server responses.
final class ImapResponseLimits {
  const ImapResponseLimits({
    this.maxLiteralBytes = 100 * 1024 * 1024,
    this.maxResponseBytes = 200 * 1024 * 1024,
    this.maxNesting = 64,
    this.maxValues = 1000000,
  });

  /// Largest single literal (one message body or part).
  final int maxLiteralBytes;

  /// Largest total of literals in one response.
  final int maxResponseBytes;

  /// Deepest list nesting (BODYSTRUCTURE nests with the MIME tree).
  final int maxNesting;

  /// Most values in one response.
  final int maxValues;
}

/// Reads and parses IMAP responses one at a time.
///
/// Parsing is lenient where servers commonly deviate (extra spaces, lower
/// case keywords) and strict where safety matters (limits, literal sizes).
/// Anything unparseable raises [MailProtocolException].
final class ImapResponseReader {
  ImapResponseReader(this._source, {this.limits = const ImapResponseLimits()});

  final LineSource _source;
  final ImapResponseLimits limits;

  Future<ImapResponse> next({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final cursor = _Cursor(
      await _source.readLine(timeout: timeout),
      _source,
      limits,
      timeout,
    );
    if (cursor.peekByte == 0x2B) {
      // "+ text" (text may be empty, and some servers omit the space)
      cursor.skip(1);
      cursor.skipSpaces();
      return ImapContinuation(cursor.restAsText());
    }
    final tag = cursor.readWord();
    if (tag.isEmpty) throw const MailProtocolException('empty response line');
    cursor.skipSpaces();

    if (tag == '*') return _untagged(cursor);

    final status = _statusOf(cursor.readWord());
    if (status == null ||
        status == ImapStatus.preauth ||
        status == ImapStatus.bye) {
      throw const MailProtocolException(
        'tagged response without OK, NO or BAD',
      );
    }
    cursor.skipSpaces();
    final (code, text) = await _codeAndText(cursor);
    return ImapTaggedResponse(tag, status, code, text);
  }

  Future<ImapResponse> _untagged(_Cursor cursor) async {
    final first = cursor.readWord();
    final number = int.tryParse(first);
    if (number != null) {
      cursor.skipSpaces();
      final keyword = cursor.readWord();
      cursor.skipSpaces();
      return ImapUntaggedData(number, keyword, await cursor.readValues());
    }
    final status = _statusOf(first);
    if (status != null) {
      cursor.skipSpaces();
      final (code, text) = await _codeAndText(cursor);
      return ImapUntaggedStatus(status, code, text);
    }
    cursor.skipSpaces();
    return ImapUntaggedData(null, first, await cursor.readValues());
  }

  /// Optional "[CODE args]" then human-readable text.
  Future<(ImapResponseCode?, String)> _codeAndText(_Cursor cursor) async {
    ImapResponseCode? code;
    if (cursor.peekByte == 0x5B) {
      cursor.skip(1);
      final name = cursor.readWord(stopAtBracket: true);
      cursor.skipSpaces();
      final args = await cursor.readValues(until: 0x5D);
      if (cursor.peekByte == 0x5D) cursor.skip(1);
      code = ImapResponseCode(name, args);
      cursor.skipSpaces();
    }
    return (code, cursor.restAsText());
  }

  static ImapStatus? _statusOf(String word) => switch (word.toUpperCase()) {
    'OK' => ImapStatus.ok,
    'NO' => ImapStatus.no,
    'BAD' => ImapStatus.bad,
    'PREAUTH' => ImapStatus.preauth,
    'BYE' => ImapStatus.bye,
    _ => null,
  };
}

/// Position in the current line, able to pull literals and continuation
/// lines from the source when a value spans them.
final class _Cursor {
  _Cursor(this._line, this._source, this._limits, this._timeout);

  Uint8List _line;
  int _pos = 0;
  final LineSource _source;
  final ImapResponseLimits _limits;
  final Duration _timeout;
  int _literalBytes = 0;
  int _values = 0;

  int? get peekByte => _pos < _line.length ? _line[_pos] : null;

  void skip(int n) => _pos += n;

  void skipSpaces() {
    while (_pos < _line.length && _line[_pos] == 0x20) {
      _pos++;
    }
  }

  String restAsText() {
    final rest = Uint8List.sublistView(
      _line,
      _pos < _line.length ? _pos : _line.length,
    );
    _pos = _line.length;
    return utf8.decode(rest, allowMalformed: true).trim();
  }

  /// A run of non-space characters (tag, keyword, status, code name).
  String readWord({bool stopAtBracket = false}) {
    final start = _pos;
    while (_pos < _line.length) {
      final c = _line[_pos];
      if (c == 0x20 || (stopAtBracket && c == 0x5D)) break;
      _pos++;
    }
    return latin1.decode(Uint8List.sublistView(_line, start, _pos));
  }

  /// Values up to the end of the response (or to [until], e.g. "]").
  Future<List<ImapValue>> readValues({int? until, int depth = 0}) async {
    final values = <ImapValue>[];
    while (true) {
      skipSpaces();
      final c = peekByte;
      if (c == null || c == until) return values;
      if (c == 0x29) {
        if (depth > 0) return values;
        throw const MailProtocolException('unbalanced ")" in response');
      }
      values.add(await _readValue(depth));
    }
  }

  Future<ImapValue> _readValue(int depth) async {
    if (++_values > _limits.maxValues) {
      throw const MailProtocolException('response has too many values');
    }
    final c = peekByte!;
    if (c == 0x28) {
      if (depth + 1 > _limits.maxNesting) {
        throw const MailProtocolException('response nests too deeply');
      }
      _pos++;
      final items = await readValues(depth: depth + 1);
      if (peekByte != 0x29) {
        throw const MailProtocolException('missing ")" in response');
      }
      _pos++;
      return ImapList(items);
    }
    if (c == 0x22) return _readQuoted();
    if (c == 0x7B ||
        (c == 0x7E && _pos + 1 < _line.length && _line[_pos + 1] == 0x7B)) {
      return _readLiteral();
    }
    final atom = _readAtom();
    if (atom.toUpperCase() == 'NIL') return const ImapNil();
    return ImapAtom(atom);
  }

  ImapString _readQuoted() {
    _pos++; // opening quote
    final out = BytesBuilder(copy: false);
    while (_pos < _line.length) {
      final c = _line[_pos++];
      if (c == 0x5C && _pos < _line.length) {
        out.addByte(_line[_pos++]);
      } else if (c == 0x22) {
        return ImapString(out.takeBytes());
      } else {
        out.addByte(c);
      }
    }
    throw const MailProtocolException('unterminated quoted string');
  }

  /// `{n}` or `{n+}` (or `~{n}` for binary) at the end of the line, then n
  /// bytes, then the response continues on the next line.
  Future<ImapString> _readLiteral() async {
    if (_line[_pos] == 0x7E) _pos++;
    final close = _line.indexOf(0x7D, _pos);
    if (close < 0 || close != _line.length - 1) {
      throw const MailProtocolException('malformed literal');
    }
    var digits = latin1.decode(Uint8List.sublistView(_line, _pos + 1, close));
    if (digits.endsWith('+') || digits.endsWith('-')) {
      digits = digits.substring(0, digits.length - 1);
    }
    final length = digits.length <= 12 ? int.tryParse(digits) : null;
    if (length == null || length < 0) {
      throw const MailProtocolException('malformed literal size');
    }
    if (length > _limits.maxLiteralBytes) {
      throw MailProtocolException('literal of $length bytes exceeds the limit');
    }
    _literalBytes += length;
    if (_literalBytes > _limits.maxResponseBytes) {
      throw const MailProtocolException('response too large');
    }
    final bytes = await _source.readBytes(length, timeout: _timeout * 2);
    _line = await _source.readLine(timeout: _timeout);
    _pos = 0;
    return ImapString(bytes);
  }

  /// An atom, including bracketed sections such as `BODY[HEADER.FIELDS
  /// (FROM TO)]<0>` which may contain spaces and parentheses.
  String _readAtom() {
    final start = _pos;
    var brackets = 0;
    while (_pos < _line.length) {
      final c = _line[_pos];
      if (c == 0x5B) {
        brackets++;
      } else if (c == 0x5D) {
        if (brackets == 0) break; // end of a response code
        brackets--;
      } else if (brackets == 0 &&
          (c == 0x20 || c == 0x28 || c == 0x29 || c == 0x22 || c < 0x20)) {
        break;
      }
      _pos++;
    }
    if (_pos == start) {
      // A stray character we cannot parse; consume it so we always move on.
      _pos++;
      throw const MailProtocolException('unexpected character in response');
    }
    return latin1.decode(Uint8List.sublistView(_line, start, _pos));
  }
}
