// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'mailbox_name.dart';
import 'sequence_set.dart';

/// A piece of a command: text, or a literal (sent with a length prefix).
sealed class CommandPart {
  const CommandPart();
}

final class TextPart extends CommandPart {
  const TextPart(this.text);

  /// Always printable ASCII without CR or LF.
  final String text;
}

final class LiteralPart extends CommandPart {
  const LiteralPart(this.bytes);

  final Uint8List bytes;
}

/// Builds one IMAP command safely.
///
/// Every value goes through a typed method that either validates it
/// (atoms, numbers, sets) or encodes it (quoted strings, literals), so text
/// from the user or from a message can never add a CRLF and inject a
/// second command.
final class ImapCommand {
  ImapCommand(String name) {
    atom(name);
  }

  final List<CommandPart> _parts = [];
  final StringBuffer _text = StringBuffer();

  /// Shown instead of the real command in errors and logs (for commands
  /// that carry secrets, such as LOGIN).
  String? redacted;

  static final _atomPattern = RegExp(r'^[\x21-\x7E]+$');
  static const _atomSpecials = '(){ %*"\\]';

  /// A keyword or flag, e.g. `FLAGS`, `\Seen`, `BODY.PEEK[]`.
  ImapCommand atom(String value) {
    if (!_atomPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'not a valid IMAP atom');
    }
    return _write(value);
  }

  /// A flag or keyword that came from outside (for example a user-defined
  /// keyword). Stricter than [atom]: no specials at all.
  ImapCommand flag(String value) {
    final body = value.startsWith(r'\') ? value.substring(1) : value;
    if (body.isEmpty ||
        !_atomPattern.hasMatch(body) ||
        body.split('').any(_atomSpecials.contains)) {
      throw ArgumentError.value(value, 'value', 'not a valid IMAP flag');
    }
    return _write(value);
  }

  ImapCommand number(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'must not be negative');
    }
    return _write('$value');
  }

  ImapCommand sequenceSet(SequenceSet set) {
    if (set.isEmpty) throw ArgumentError('empty sequence set');
    return _write(set.toString());
  }

  /// A string: quoted when it is short printable ASCII, otherwise a
  /// literal (which can carry any bytes except NUL).
  ImapCommand string(String value) => bytes(utf8.encode(value));

  ImapCommand bytes(List<int> value) {
    if (value.contains(0)) {
      throw ArgumentError('IMAP strings cannot contain NUL');
    }
    final quotable =
        value.length <= 1000 && value.every((b) => b >= 0x20 && b <= 0x7E);
    if (quotable) {
      final text = latin1
          .decode(value)
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"');
      return _write('"$text"');
    }
    return literal(value);
  }

  /// A mailbox name, encoded as modified UTF-7.
  ImapCommand mailbox(String name) => string(MailboxNameCodec.encode(name));

  /// Raw message data (APPEND) as a literal.
  ImapCommand literal(List<int> value) {
    _space();
    _parts.add(TextPart(_text.toString()));
    _text.clear();
    _parts.add(
      LiteralPart(value is Uint8List ? value : Uint8List.fromList(value)),
    );
    return this;
  }

  /// Fixed syntax written by this library, such as `(UID FLAGS)`. Must
  /// never contain outside text; checked to be printable ASCII.
  ImapCommand raw(String syntax) {
    if (!RegExp(r'^[\x20-\x7E]+$').hasMatch(syntax)) {
      throw ArgumentError.value(syntax, 'syntax', 'must be printable ASCII');
    }
    return _write(syntax);
  }

  /// Opens "(" so values can be added inside, e.g. flag lists.
  ImapCommand openList() {
    _space();
    _text.write('(');
    _justOpened = true;
    return this;
  }

  ImapCommand closeList() {
    _text.write(')');
    return this;
  }

  /// The command split at literals. The first text part does not yet
  /// include the tag.
  List<CommandPart> build() => [..._parts, TextPart(_text.toString())];

  /// The command as text with literals replaced, for error messages.
  String describe() =>
      redacted ??
      build().map((p) => p is TextPart ? p.text : '{literal}').join();

  /// True right after "(", where no separating space is wanted.
  bool _justOpened = false;

  ImapCommand _write(String token) {
    _space();
    _text.write(token);
    return this;
  }

  /// A space between tokens: not at the very start and not after "(".
  /// After a literal the text restarts empty, but a space is still needed.
  void _space() {
    final atStart = _text.isEmpty && _parts.isEmpty;
    if (!atStart && !_justOpened) _text.write(' ');
    _justOpened = false;
  }
}
