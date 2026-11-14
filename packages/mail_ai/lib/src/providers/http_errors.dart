// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import '../ai_errors.dart';
import '../transport/ai_http.dart';

/// Reads at most [max] bytes of [body] as text.
Future<String> readText(Stream<List<int>> body, {int max = 4 << 20}) async {
  final bytes = <int>[];
  await for (final chunk in body) {
    bytes.addAll(chunk);
    if (bytes.length > max) {
      throw const AiException(AiProblem.badResponse, 'the answer is too large');
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Reads a JSON object answer.
Future<Map<String, Object?>> readJson(AiHttpResponse response) async {
  final text = await readText(response.body);
  try {
    final value = jsonDecode(text);
    if (value is Map<String, Object?>) return value;
  } on FormatException {
    // below
  }
  throw const AiException(AiProblem.badResponse, 'not a JSON answer');
}

/// The [AiException] for an unsuccessful answer: by its status, and the
/// error's type, code and message where the body has them (both the
/// Anthropic and the OpenAI shape: `{"error": {"type", "code",
/// "message"}}`).
Future<AiException> errorFrom(AiHttpResponse response) async {
  String text;
  try {
    text = await readText(response.body, max: 64 * 1024);
  } on AiException {
    text = '';
  }
  String? type, code, message;
  try {
    final json = jsonDecode(text);
    if (json is Map<String, Object?>) {
      final error = json['error'];
      if (error is Map<String, Object?>) {
        type = error['type'] as String?;
        code = error['code']?.toString();
        message = error['message'] as String?;
      } else if (error is String) {
        message = error;
      } else if (json['detail'] is String) {
        message = json['detail']! as String;
      } else if (json['message'] is String) {
        message = json['message']! as String;
      }
    }
  } on FormatException {
    // Not JSON: the status decides.
  } on TypeError {
    // An unexpected shape: the status decides.
  }
  final status = response.statusCode;
  final detail = _short(message ?? 'status $status');
  final words = '${type ?? ''} ${code ?? ''} ${message ?? ''}'.toLowerCase();
  bool says(List<String> phrases) => phrases.any(words.contains);
  if (says(['insufficient_quota', 'credit balance', 'billing'])) {
    return AiException(AiProblem.billing, detail);
  }
  if (status == 413 ||
      says([
        'context_length_exceeded',
        'context length',
        'prompt is too long',
        'too many tokens',
        'maximum context',
        'context window',
      ])) {
    return AiException(AiProblem.contextTooLong, detail);
  }
  return switch (status) {
    401 => AiException(AiProblem.badKey, detail),
    402 => AiException(AiProblem.billing, detail),
    404 => AiException(AiProblem.modelNotFound, detail),
    429 => AiException(
      AiProblem.rateLimited,
      detail,
      retryAfter: retryAfter(response.headers),
    ),
    >= 500 => AiException(AiProblem.server, detail),
    _ => AiException(AiProblem.badRequest, detail),
  };
}

/// The wait a `retry-after` (seconds or an HTTP date) or
/// `retry-after-ms` header asks for.
Duration? retryAfter(Map<String, String> headers, {DateTime? now}) {
  if (int.tryParse(headers['retry-after-ms'] ?? '') case final ms?) {
    return Duration(milliseconds: ms);
  }
  final value = headers['retry-after']?.trim();
  if (value == null || value.isEmpty) return null;
  if (double.tryParse(value) case final seconds?) {
    return Duration(milliseconds: (seconds * 1000).round());
  }
  try {
    final at = HttpDateParser.parse(value);
    final wait = at.difference(now ?? DateTime.now().toUtc());
    return wait.isNegative ? Duration.zero : wait;
  } on FormatException {
    return null;
  }
}

String _short(String text) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > 300 ? '${one.substring(0, 300)}…' : one;
}

/// Parses an HTTP date (`Wed, 21 Oct 2026 07:28:00 GMT`).
abstract final class HttpDateParser {
  static const _months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  static DateTime parse(String text) {
    final m = RegExp(
      r'^\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(text.trim());
    final month = m == null ? -1 : _months.indexOf(m[2]!.toLowerCase());
    if (m == null || month < 0) throw const FormatException('not a date');
    return DateTime.utc(
      int.parse(m[3]!),
      month + 1,
      int.parse(m[1]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }
}
