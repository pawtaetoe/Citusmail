// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mail_web/mail_web.dart';

import 'safe_browsing_url.dart';

/// The lists the app keeps (URL lists for any platform).
enum ThreatType {
  malware('MALWARE'),
  socialEngineering('SOCIAL_ENGINEERING'),
  unwantedSoftware('UNWANTED_SOFTWARE');

  const ThreatType(this.apiName);

  final String apiName;

  static ThreatType? fromApi(Object? name) =>
      values.where((t) => t.apiName == name).firstOrNull;
}

/// One downloaded list: hash prefixes (4 bytes each, a few longer), kept
/// sorted, and the state Google gave with them.
final class PrefixList {
  PrefixList({this.state = '', Uint32List? short, List<Uint8List>? long})
    : short = short ?? Uint32List(0),
      long = long ?? const [];

  /// Opaque, base64; empty means "send everything" (a full update).
  String state;

  /// 4-byte prefixes as big-endian numbers, ascending (= byte order).
  Uint32List short;

  /// Longer prefixes, in byte order.
  List<Uint8List> long;

  int get length => short.length + long.length;

  /// Every prefix in byte order, as Google numbers them for removals and
  /// hashes them for the checksum.
  Iterable<Uint8List> get ordered sync* {
    var i = 0, j = 0;
    while (i < short.length || j < long.length) {
      if (j >= long.length ||
          (i < short.length && _compare(_bytes(short[i]), long[j]) <= 0)) {
        yield _bytes(short[i++]);
      } else {
        yield long[j++];
      }
    }
  }

  /// Applies an update: drops the prefixes at [removals] (indices into
  /// [ordered] before the update), adds [additions], keeps byte order.
  void apply({
    required Iterable<int> removals,
    required Iterable<Uint8List> additions,
  }) {
    final drop = removals.toSet();
    final shortOut = <int>[];
    final longOut = <Uint8List>[];
    var index = 0;
    for (final prefix in ordered) {
      if (!drop.contains(index++)) _add(prefix, shortOut, longOut);
    }
    for (final prefix in additions) {
      _add(prefix, shortOut, longOut);
    }
    shortOut.sort();
    longOut.sort(_compare);
    short = Uint32List.fromList(_unique(shortOut));
    long = [
      for (var k = 0; k < longOut.length; k++)
        if (k == 0 || _compare(longOut[k - 1], longOut[k]) != 0) longOut[k],
    ];
  }

  /// SHA-256 of all prefixes in byte order (Google's checksum).
  Uint8List checksum() {
    final out = BytesBuilder(copy: false);
    for (final prefix in ordered) {
      out.add(prefix);
    }
    return Uint8List.fromList(sha256.convert(out.takeBytes()).bytes);
  }

  /// The stored prefix of [fullHash], if any.
  Uint8List? match(Uint8List fullHash) {
    final value = _value(fullHash);
    var lo = 0, hi = short.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = short[mid];
      if (v == value) return _bytes(v);
      if (v < value) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    for (final prefix in long) {
      if (prefix.length <= fullHash.length &&
          _compare(prefix, Uint8List.sublistView(fullHash, 0, prefix.length)) ==
              0) {
        return prefix;
      }
    }
    return null;
  }

  static void _add(Uint8List prefix, List<int> short, List<Uint8List> long) {
    if (prefix.length == 4) {
      short.add(_value(prefix));
    } else if (prefix.length > 4 && prefix.length <= 32) {
      long.add(prefix);
    }
  }

  static List<int> _unique(List<int> sorted) => [
    for (var k = 0; k < sorted.length; k++)
      if (k == 0 || sorted[k - 1] != sorted[k]) sorted[k],
  ];

  static int _value(Uint8List b) =>
      (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

  static Uint8List _bytes(int v) => Uint8List.fromList([
    v >> 24 & 0xFF,
    v >> 16 & 0xFF,
    v >> 8 & 0xFF,
    v & 0xFF,
  ]);

  static int _compare(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}

/// The downloaded lists, and when Google allows the next update. Saved by
/// the app as one file ([encode] / [decode]): public data, nothing about
/// the user.
final class SafeBrowsingDatabase {
  SafeBrowsingDatabase({Map<ThreatType, PrefixList>? lists, this.nextUpdate})
    : lists = lists ?? {for (final t in ThreatType.values) t: PrefixList()};

  final Map<ThreatType, PrefixList> lists;
  DateTime? nextUpdate;

  bool get isEmpty => lists.values.every((l) => l.length == 0);

  static const _magic = 'CMSB1';

  Uint8List encode() {
    final out = BytesBuilder(copy: false)..add(ascii.encode(_magic));
    void u32(int v) =>
        out.add([v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF]);
    void bytes(List<int> b) {
      u32(b.length);
      out.add(b);
    }

    bytes(utf8.encode('${nextUpdate?.toUtc().millisecondsSinceEpoch ?? 0}'));
    u32(lists.length);
    for (final MapEntry(key: type, value: list) in lists.entries) {
      bytes(ascii.encode(type.apiName));
      bytes(ascii.encode(list.state));
      final short = ByteData(list.short.length * 4);
      for (var i = 0; i < list.short.length; i++) {
        short.setUint32(i * 4, list.short[i]);
      }
      bytes(short.buffer.asUint8List());
      u32(list.long.length);
      for (final prefix in list.long) {
        bytes(prefix);
      }
    }
    return out.takeBytes();
  }

  /// Null for anything unreadable (then the lists are downloaded afresh).
  static SafeBrowsingDatabase? decode(Uint8List data) {
    try {
      final view = ByteData.sublistView(data);
      var at = 0;
      int u32() {
        final v = view.getUint32(at);
        at += 4;
        return v;
      }

      Uint8List bytes() {
        final n = u32();
        if (n > data.length - at) throw const FormatException('truncated');
        final b = Uint8List.sublistView(data, at, at + n);
        at += n;
        return b;
      }

      if (ascii.decode(Uint8List.sublistView(data, 0, 5)) != _magic) {
        return null;
      }
      at = 5;
      final millis = int.parse(utf8.decode(bytes()));
      final db = SafeBrowsingDatabase(
        nextUpdate: millis == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      );
      final count = u32();
      for (var i = 0; i < count; i++) {
        final type = ThreatType.fromApi(ascii.decode(bytes()));
        final state = ascii.decode(bytes());
        final shortBytes = bytes();
        final short = Uint32List(shortBytes.length ~/ 4);
        final shortView = ByteData.sublistView(shortBytes);
        for (var k = 0; k < short.length; k++) {
          short[k] = shortView.getUint32(k * 4);
        }
        final longCount = u32();
        final long = [
          for (var k = 0; k < longCount; k++) Uint8List.fromList(bytes()),
        ];
        if (type != null) {
          db.lists[type] = PrefixList(state: state, short: short, long: long);
        }
      }
      return db;
    } on Object {
      return null;
    }
  }
}

/// What a link check found.
final class SafeBrowsingVerdict {
  const SafeBrowsingVerdict(this.threat);

  /// Null: not on Google's lists.
  final ThreatType? threat;

  bool get listed => threat != null;
}

/// Google Safe Browsing (Update API v4) through the hardened [WebClient]:
/// the hash lists are downloaded and links are checked on the device.
/// Only when a link's hash starts like one in the lists is that 4-byte
/// start sent to Google, to confirm with the full hashes; the link itself
/// never is.
final class SafeBrowsingClient {
  SafeBrowsingClient(
    this._web,
    this.apiKey,
    this.database, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final WebClient _web;
  final String apiKey;
  final SafeBrowsingDatabase database;
  final DateTime Function() _now;

  static const _base = 'https://safebrowsing.googleapis.com/v4/';
  static const _client = {'clientId': 'citusmail', 'clientVersion': '1'};
  static const _maxUpdate = 64 * 1024 * 1024;

  /// Full-hash answers: hash (hex) -> (until, threat or null).
  final _cache = <String, (DateTime, ThreatType?)>{};

  /// Prefixes Google said nothing about, until when.
  final _negative = <String, DateTime>{};

  bool get updateDue {
    final next = database.nextUpdate;
    return next == null || !_now().toUtc().isBefore(next);
  }

  /// Downloads list changes (all of them the first time). Lists whose
  /// checksum doesn't match are emptied, to be downloaded afresh next time.
  /// Throws [WebException] or [FormatException].
  Future<void> update() async {
    final json = await _post('threatListUpdates:fetch', {
      'client': _client,
      'listUpdateRequests': [
        for (final MapEntry(key: type, value: list) in database.lists.entries)
          {
            'threatType': type.apiName,
            'platformType': 'ANY_PLATFORM',
            'threatEntryType': 'URL',
            'state': list.state,
            'constraints': {
              'supportedCompressions': ['RAW'],
            },
          },
      ],
    }, maxAnswer: _maxUpdate);
    for (final response in (json['listUpdateResponses'] as List? ?? const [])) {
      if (response is! Map) continue;
      final type = ThreatType.fromApi(response['threatType']);
      final list = type == null ? null : database.lists[type];
      if (list == null) continue;
      if (response['responseType'] == 'FULL_UPDATE') {
        list
          ..short = Uint32List(0)
          ..long = const [];
      }
      list.apply(
        removals: [
          for (final r in (response['removals'] as List? ?? const []))
            if (r is Map && r['rawIndices'] is Map)
              for (final i
                  in ((r['rawIndices'] as Map<Object?, Object?>)['indices']
                          as List? ??
                      const []))
                if (i is int) i,
        ],
        additions: [
          for (final a in (response['additions'] as List? ?? const []))
            if (a is Map && a['rawHashes'] is Map)
              ..._split(a['rawHashes'] as Map<Object?, Object?>),
        ],
      );
      final expected =
          (response['checksum'] as Map<Object?, Object?>?)?['sha256'];
      if (expected is String && base64.encode(list.checksum()) != expected) {
        list
          ..state = ''
          ..short = Uint32List(0)
          ..long = const [];
        continue;
      }
      list.state = response['newClientState'] as String? ?? '';
    }
    database.nextUpdate = _now().toUtc().add(
      _duration(json['minimumWaitDuration']) ?? const Duration(minutes: 30),
    );
  }

  /// Checks [url]: on the device first; only a matching hash prefix is
  /// sent to Google to confirm. Throws [WebException] when a confirmation
  /// was needed but failed.
  Future<SafeBrowsingVerdict> check(String url) async {
    final now = _now().toUtc();
    final hashes = SafeBrowsingUrl.hashes(url);
    final prefixes = <String, Uint8List>{};
    for (final hash in hashes) {
      final cached = _cache[_hex(hash)];
      if (cached != null && now.isBefore(cached.$1)) {
        if (cached.$2 != null) return SafeBrowsingVerdict(cached.$2);
        continue;
      }
      for (final list in database.lists.values) {
        final prefix = list.match(hash);
        if (prefix == null) continue;
        final key = _hex(prefix);
        final quiet = _negative[key];
        if (quiet == null || !now.isBefore(quiet)) prefixes[key] = prefix;
      }
    }
    if (prefixes.isEmpty) return const SafeBrowsingVerdict(null);

    final json = await _post('fullHashes:find', {
      'client': _client,
      'clientStates': [for (final l in database.lists.values) l.state],
      'threatInfo': {
        'threatTypes': [for (final t in ThreatType.values) t.apiName],
        'platformTypes': ['ANY_PLATFORM'],
        'threatEntryTypes': ['URL'],
        'threatEntries': [
          for (final p in prefixes.values) {'hash': base64.encode(p)},
        ],
      },
    }, maxAnswer: 1024 * 1024);
    final negativeUntil = now.add(
      _duration(json['negativeCacheDuration']) ?? const Duration(minutes: 5),
    );
    for (final key in prefixes.keys) {
      _negative[key] = negativeUntil;
    }
    final mine = {for (final h in hashes) _hex(h)};
    ThreatType? found;
    for (final m in (json['matches'] as List? ?? const [])) {
      if (m is! Map) continue;
      final hash = (m['threat'] as Map<Object?, Object?>?)?['hash'];
      final type = ThreatType.fromApi(m['threatType']);
      if (hash is! String || type == null) continue;
      final key = _hex(base64.decode(hash));
      _cache[key] = (
        now.add(_duration(m['cacheDuration']) ?? const Duration(minutes: 5)),
        type,
      );
      if (mine.contains(key)) found ??= type;
    }
    for (final h in hashes) {
      _cache.putIfAbsent(_hex(h), () => (negativeUntil, null));
    }
    if (_cache.length > 5000) _cache.clear();
    if (_negative.length > 5000) _negative.clear();
    return SafeBrowsingVerdict(found);
  }

  Future<Map<String, Object?>> _post(
    String method,
    Map<String, Object?> body, {
    required int maxAnswer,
  }) async {
    final response = await _web.post(
      Uri.parse('$_base$method').replace(queryParameters: {'key': apiKey}),
      body: utf8.encode(jsonEncode(body)),
      contentType: 'application/json',
      maxAnswer: maxAnswer,
    );
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body ?? const []));
    } on FormatException {
      throw WebException(
        WebProblem.badResponse,
        'Safe Browsing answered ${response.statusCode}',
      );
    }
    if (!response.ok || json is! Map<String, Object?>) {
      final message = switch (json) {
        {'error': {'message': final String text}} => text,
        _ => null,
      };
      throw WebException(
        WebProblem.notAvailable,
        'Safe Browsing refused (${response.statusCode})'
        '${message == null ? '' : ': $message'}',
      );
    }
    return json;
  }

  static Iterable<Uint8List> _split(Map<Object?, Object?> raw) sync* {
    final size = raw['prefixSize'];
    final data = raw['rawHashes'];
    if (size is! int || size < 4 || size > 32 || data is! String) return;
    final bytes = base64.decode(data);
    for (var i = 0; i + size <= bytes.length; i += size) {
      yield Uint8List.sublistView(bytes, i, i + size);
    }
  }

  /// "593.440s" -> a duration.
  static Duration? _duration(Object? text) {
    if (text is! String || !text.endsWith('s')) return null;
    final seconds = double.tryParse(text.substring(0, text.length - 1));
    if (seconds == null || seconds < 0 || seconds > 86400 * 7) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
