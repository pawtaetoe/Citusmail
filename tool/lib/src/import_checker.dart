// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// One rule: code matching [pattern] is only allowed in [allowedIn].
final class ImportRule {
  const ImportRule(this.pattern, this.reason, {this.allowedIn = const []});

  final RegExp pattern;
  final String reason;

  /// Path prefixes (relative to the repository root) where it is allowed.
  final List<String> allowedIn;
}

/// A line that breaks a rule.
final class ImportViolation {
  const ImportViolation(this.path, this.line, this.reason);

  final String path;
  final int line;
  final String reason;

  @override
  String toString() => '$path:$line: $reason';
}

/// Keeps network code where it was reviewed: shipped code (app and package
/// `lib/` folders) may not pull in HTTP clients, web views or code that
/// downloads data, except where the review allows it.
final class ImportChecker {
  ImportChecker({List<ImportRule>? rules}) : rules = rules ?? defaultRules;

  final List<ImportRule> rules;

  static final defaultRules = [
    ImportRule(
      RegExp(r'''import\s+['"]package:http/'''),
      'package:http is not used by this app (no HTTP client may ship)',
    ),
    ImportRule(
      RegExp(r'''import\s+['"]package:timezone/(standalone|browser)\.dart'''),
      'this timezone entry point can download data over HTTP',
    ),
    ImportRule(
      RegExp(
        r'''import\s+['"]package:(webview|flutter_inappwebview|web_socket)''',
      ),
      'web views and sockets to the web are not allowed',
    ),
    ImportRule(
      RegExp(r'\bHttpClient\s*\('),
      'HTTP is only used by account setup, after review',
      allowedIn: ['packages/mail_setup/lib/'],
    ),
    ImportRule(
      RegExp(
        r'\b(RawSocket|Socket|SecureSocket|RawSecureSocket)\s*\.\s*(connect|startConnect|secure)\s*\(',
      ),
      'connections are opened only by MailSocket in mail_protocol (TLS rules)',
      allowedIn: ['packages/mail_protocol/lib/'],
    ),
    ImportRule(
      RegExp(r'\bRawDatagramSocket\s*\.\s*bind\s*\('),
      'UDP is only used for DNS lookups during account setup',
      allowedIn: ['packages/mail_setup/lib/'],
    ),
    ImportRule(
      RegExp(r'\bMailSocket\s*\.\s*connect\s*\('),
      'servers named inside mail are contacted only through mail_web',
      allowedIn: ['packages/mail_protocol/lib/', 'packages/mail_web/lib/'],
    ),
  ];

  /// Violations in one file's [content] at [path] (repository relative).
  List<ImportViolation> check(String path, String content) {
    final violations = <ImportViolation>[];
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      for (final rule in rules) {
        if (!rule.pattern.hasMatch(line)) continue;
        if (rule.allowedIn.any(path.startsWith)) continue;
        violations.add(ImportViolation(path, i + 1, rule.reason));
      }
    }
    return violations;
  }
}
