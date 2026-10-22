// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// One `Authentication-Results` header (RFC 8601): what a mail server
/// found when it checked SPF, DKIM and DMARC.
///
/// Anyone can write this header into a message, so a result only counts
/// when it comes from the user's own server (see [AuthServIds]).
final class AuthenticationResults {
  const AuthenticationResults(this.authServId, this.results);

  /// The name of the server that did the checks, lower case.
  final String authServId;
  final List<AuthResult> results;

  /// Longest header value read; longer ones are cut (hostile mail).
  static const maxLength = 16 * 1024;

  /// Most results read from one header.
  static const maxResults = 50;

  /// Parses a header value; null if it has no authserv-id.
  static AuthenticationResults? parse(String value) {
    final tokens = _Tokenizer(
      value.length > maxLength ? value.substring(0, maxLength) : value,
    ).tokens();
    if (tokens.isEmpty || tokens.first.kind != _Kind.word) return null;
    final id = tokens.first.text.toLowerCase();

    final results = <AuthResult>[];
    // Statements are separated by ";". The first is the authserv-id (and
    // an optional version number).
    var statement = <_Token>[];
    void finish() {
      final result = _result(statement);
      if (result != null && results.length < maxResults) results.add(result);
      statement = [];
    }

    final semicolon = tokens.indexWhere((t) => t.kind == _Kind.semicolon);
    if (semicolon < 0) return AuthenticationResults(id, const []);
    for (final token in tokens.skip(semicolon + 1)) {
      if (token.kind == _Kind.semicolon) {
        finish();
      } else {
        statement.add(token);
      }
    }
    finish();
    return AuthenticationResults(id, List.unmodifiable(results));
  }

  /// `method=result` followed by `reason=...` and `ptype.property=value`
  /// pairs; null for `none` or anything unreadable.
  static AuthResult? _result(List<_Token> s) {
    if (s.length < 3 || s[1].kind != _Kind.equals) return null;
    final method = s[0].text.toLowerCase().split('/').first;
    final result = s[2].text.toLowerCase();
    final properties = <String, String>{};
    for (var i = 3; i + 2 < s.length; i++) {
      if (s[i].kind == _Kind.word && s[i + 1].kind == _Kind.equals) {
        properties.putIfAbsent(s[i].text.toLowerCase(), () => s[i + 2].text);
        i += 2;
      }
    }
    return AuthResult(method, result, properties);
  }

  /// The DMARC result, or null if DMARC wasn't checked.
  AuthResult? get dmarc => _first('dmarc');

  AuthResult? get spf => _first('spf');

  Iterable<AuthResult> get dkim => results.where((r) => r.method == 'dkim');

  AuthResult? _first(String method) {
    for (final r in results) {
      if (r.method == method) return r;
    }
    return null;
  }
}

/// One check: `dkim=pass header.d=example.com`.
final class AuthResult {
  const AuthResult(this.method, this.result, this.properties);

  /// `spf`, `dkim`, `dmarc`...
  final String method;

  /// `pass`, `fail`, `softfail`, `neutral`, `none`, `temperror`...
  final String result;

  /// `header.d`, `smtp.mailfrom`, `header.from`, `reason`..., as written.
  final Map<String, String> properties;

  bool get passed => result == 'pass';
  bool get failed => result == 'fail';

  /// The domain the check was about: `header.from` for DMARC, `header.d`
  /// (or `header.i`) for DKIM, `smtp.mailfrom` for SPF.
  String? get domain {
    final value = switch (method) {
      'dmarc' => properties['header.from'],
      'dkim' => properties['header.d'] ?? properties['header.i'],
      'spf' => properties['smtp.mailfrom'] ?? properties['smtp.helo'],
      _ => null,
    };
    if (value == null) return null;
    final at = value.lastIndexOf('@');
    return (at >= 0 ? value.substring(at + 1) : value).toLowerCase();
  }
}

/// Which `Authentication-Results` headers to believe.
///
/// A server adds its own result at the top of the message, and a well
/// behaved one removes forged copies that claim its name. So the id that
/// sits at the top of most recent incoming mail is the user's own server;
/// results from any other id may have been written by the sender.
abstract final class AuthServIds {
  /// Messages needed before an id is trusted.
  static const minimumMessages = 5;

  /// Share of recent messages that must carry the id at the top.
  static const minimumShare = 0.6;

  /// The trusted id given the topmost `Authentication-Results` value of
  /// each recent incoming message (null for a message without one), or
  /// null if no id is common enough yet.
  static String? learn(Iterable<String?> topmostValues) {
    var total = 0;
    final counts = <String, int>{};
    for (final value in topmostValues) {
      total++;
      final id = value == null
          ? null
          : AuthenticationResults.parse(value)?.authServId;
      if (id != null) counts[id] = (counts[id] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
    if (best.value < minimumMessages) return null;
    if (best.value < total * minimumShare) return null;
    return best.key;
  }

  /// The results from [trustedId] in a message's headers ([values] top
  /// first): the run at the top written by the trusted server. A result
  /// under a different id stops the run; anything below it could be
  /// forged.
  static List<AuthenticationResults> trusted(
    Iterable<String> values,
    String? trustedId,
  ) {
    if (trustedId == null) return const [];
    final out = <AuthenticationResults>[];
    for (final value in values) {
      final parsed = AuthenticationResults.parse(value);
      if (parsed == null || parsed.authServId != trustedId) break;
      out.add(parsed);
    }
    return out;
  }
}

enum _Kind { word, equals, semicolon }

final class _Token {
  const _Token(this.kind, this.text);

  final _Kind kind;
  final String text;
}

/// Splits a header value into words, `=` and `;`, dropping comments
/// (nested parentheses) and unquoting quoted strings.
final class _Tokenizer {
  _Tokenizer(this.input);

  final String input;
  var _pos = 0;

  List<_Token> tokens() {
    final out = <_Token>[];
    while (_pos < input.length) {
      final c = input[_pos];
      if (c == '(') {
        _skipComment();
      } else if (c == '"') {
        out.add(_Token(_Kind.word, _quoted()));
      } else if (c == '=') {
        out.add(const _Token(_Kind.equals, '='));
        _pos++;
      } else if (c == ';') {
        out.add(const _Token(_Kind.semicolon, ';'));
        _pos++;
      } else if (c.trim().isEmpty) {
        _pos++;
      } else {
        final start = _pos;
        while (_pos < input.length && !'()";= \t\r\n'.contains(input[_pos])) {
          _pos++;
        }
        out.add(_Token(_Kind.word, input.substring(start, _pos)));
      }
    }
    return out;
  }

  void _skipComment() {
    var depth = 0;
    while (_pos < input.length) {
      final c = input[_pos++];
      if (c == r'\') {
        _pos++;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        if (--depth == 0) return;
      }
    }
  }

  String _quoted() {
    final out = StringBuffer();
    _pos++; // opening quote
    while (_pos < input.length) {
      final c = input[_pos++];
      if (c == '"') break;
      if (c == r'\' && _pos < input.length) {
        out.write(input[_pos++]);
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }
}
