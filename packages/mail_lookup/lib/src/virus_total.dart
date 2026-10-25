// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mail_web/mail_web.dart';

/// What VirusTotal knows about a file or a link.
final class VirusTotalReport {
  const VirusTotalReport({
    required this.known,
    this.malicious = 0,
    this.suspicious = 0,
    this.harmless = 0,
    this.undetected = 0,
    this.analysedAt,
  });

  /// False: VirusTotal has never seen it (nothing was submitted).
  final bool known;
  final int malicious;
  final int suspicious;
  final int harmless;
  final int undetected;
  final DateTime? analysedAt;

  /// How many security vendors gave a verdict.
  int get engines => malicious + suspicious + harmless + undetected;

  bool get flagged => malicious + suspicious > 0;
}

/// Why a VirusTotal lookup failed, in terms the app can explain.
enum VirusTotalProblem {
  /// The API key was refused.
  badKey,

  /// The key's quota is used up (the free key allows 4 lookups a minute
  /// and 500 a day).
  quota,

  /// VirusTotal couldn't be reached or answered oddly.
  unavailable,
}

final class VirusTotalException implements Exception {
  const VirusTotalException(this.problem, this.message);

  final VirusTotalProblem problem;
  final String message;

  @override
  String toString() => 'VirusTotalException(${problem.name}): $message';
}

/// VirusTotal (API v3) with the user's own key, through the hardened
/// [WebClient]. Lookups only: a file is never uploaded (only its SHA-256
/// is sent), and a link is looked up, never submitted for scanning.
final class VirusTotalClient {
  VirusTotalClient(this._web, this.apiKey);

  final WebClient _web;
  final String apiKey;

  static const _base = 'https://www.virustotal.com/api/v3/';

  /// The SHA-256 VirusTotal is asked about for a file.
  static String fileId(List<int> bytes) => sha256.convert(bytes).toString();

  /// VirusTotal's id for a link: the address, base64url without padding.
  static String urlId(Uri link) =>
      base64Url.encode(utf8.encode(link.toString())).replaceAll('=', '');

  /// What VirusTotal knows about a file with these [bytes].
  Future<VirusTotalReport> file(List<int> bytes) =>
      _lookup('files/${fileId(bytes)}');

  /// The same, by the file's SHA-256 (64 hex digits).
  Future<VirusTotalReport> fileByHash(String sha256Hex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256Hex)) {
      throw ArgumentError.value(sha256Hex, 'sha256Hex', 'not a SHA-256');
    }
    return _lookup('files/${sha256Hex.toLowerCase()}');
  }

  /// What VirusTotal knows about [link]. This sends the address itself:
  /// the app asks only when the user does, for a link already flagged.
  Future<VirusTotalReport> url(Uri link) => _lookup('urls/${urlId(link)}');

  Future<VirusTotalReport> _lookup(String path) async {
    final WebResponse response;
    try {
      response = await _web.getApi(
        Uri.parse('$_base$path'),
        apiKeyHeader: 'x-apikey',
        apiKey: apiKey,
        maxAnswer: 2 * 1024 * 1024,
      );
    } on WebException catch (e) {
      throw VirusTotalException(VirusTotalProblem.unavailable, e.message);
    } on ArgumentError {
      throw const VirusTotalException(
        VirusTotalProblem.badKey,
        'the API key is not usable',
      );
    }
    switch (response.statusCode) {
      case 404:
        return const VirusTotalReport(known: false);
      case 401 || 403:
        throw const VirusTotalException(
          VirusTotalProblem.badKey,
          'VirusTotal didn\'t accept the API key',
        );
      case 429:
        throw const VirusTotalException(
          VirusTotalProblem.quota,
          'the API key\'s quota is used up for now',
        );
      case 200:
        break;
      default:
        throw VirusTotalException(
          VirusTotalProblem.unavailable,
          'VirusTotal answered ${response.statusCode}',
        );
    }
    try {
      final json = jsonDecode(utf8.decode(response.body ?? const []));
      final attributes = switch (json) {
        {'data': {'attributes': final Map<String, Object?> a}} => a,
        _ => throw const FormatException('no attributes'),
      };
      final stats = switch (attributes['last_analysis_stats']) {
        final Map<String, Object?> s => s,
        _ => const <String, Object?>{},
      };
      int count(String key) => switch (stats[key]) {
        final int n when n >= 0 => n,
        _ => 0,
      };
      final date = attributes['last_analysis_date'];
      return VirusTotalReport(
        known: true,
        malicious: count('malicious'),
        suspicious: count('suspicious'),
        harmless: count('harmless'),
        undetected: count('undetected'),
        analysedAt: date is int
            ? DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true)
            : null,
      );
    } on FormatException {
      throw const VirusTotalException(
        VirusTotalProblem.unavailable,
        'VirusTotal\'s answer couldn\'t be read',
      );
    }
  }
}
