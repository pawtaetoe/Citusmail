// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// One DNS SRV record (RFC 2782).
final class SrvRecord {
  const SrvRecord(this.priority, this.weight, this.port, this.target);

  final int priority;
  final int weight;
  final int port;
  final String target;
}

/// One DNS MX record (RFC 1035): where a domain's mail is delivered.
final class MxRecord {
  const MxRecord(this.preference, this.exchange);

  final int preference;
  final String exchange;
}

/// Looks up MX records. Like SRV answers, they are not authenticated.
abstract interface class MxResolver {
  /// Records for [domain], most preferred first. Empty when there are
  /// none or the lookup failed.
  Future<List<MxRecord>> lookupMx(String domain);
}

/// Looks up SRV records. Answers are not authenticated: treat them as
/// suggestions to verify, never as trusted settings.
abstract interface class SrvResolver {
  /// Records for [name], lowest priority first. Empty when there are none
  /// or the lookup failed.
  Future<List<SrvRecord>> lookup(String name);
}

/// Used where the system's DNS servers cannot be found (Android, Windows):
/// SRV discovery is skipped there rather than sending the domain to a
/// public DNS provider.
final class NoSrvResolver implements SrvResolver, MxResolver {
  const NoSrvResolver();

  @override
  Future<List<SrvRecord>> lookup(String name) async => const [];

  @override
  Future<List<MxRecord>> lookupMx(String domain) async => const [];
}

/// A minimal DNS client (RFC 1035) for SRV and MX queries over UDP to the
/// system's own resolvers, so the domain is not sent to anyone else.
final class UdpSrvResolver implements SrvResolver, MxResolver {
  UdpSrvResolver(
    this.nameservers, {
    this.timeout = const Duration(seconds: 3),
    Random? random,
  }) : _random = random ?? Random.secure();

  /// Resolvers listed in /etc/resolv.conf, or a [NoSrvResolver] when none
  /// can be found.
  static SrvResolver system() {
    try {
      final file = File('/etc/resolv.conf');
      if (!file.existsSync()) return const NoSrvResolver();
      final servers = [
        for (final line in file.readAsLinesSync())
          if (RegExp(r'^\s*nameserver\s+(\S+)').firstMatch(line) case final m?)
            ?InternetAddress.tryParse(m.group(1)!),
      ];
      return servers.isEmpty ? const NoSrvResolver() : UdpSrvResolver(servers);
    } on FileSystemException {
      return const NoSrvResolver();
    }
  }

  final List<InternetAddress> nameservers;
  final Duration timeout;
  final Random _random;

  static const _typeSrv = 33;
  static const _typeMx = 15;

  @override
  Future<List<MxRecord>> lookupMx(String domain) async {
    for (final server in nameservers) {
      try {
        final data = await _query(server, domain, _typeMx);
        if (data != null) {
          return DnsMessage.parseMxAnswer(data.$1, data.$2, domain)
            ..sort((a, b) => a.preference.compareTo(b.preference));
        }
      } on Object {
        // try the next server
      }
    }
    return const [];
  }

  @override
  Future<List<SrvRecord>> lookup(String name) async {
    for (final server in nameservers) {
      try {
        final data = await _query(server, name, _typeSrv);
        final records = data == null
            ? null
            : DnsMessage.parseSrvAnswer(data.$1, data.$2, name);
        if (records != null) {
          records.sort(
            (a, b) => a.priority != b.priority
                ? a.priority.compareTo(b.priority)
                : b.weight.compareTo(a.weight),
          );
          return records;
        }
      } on Object {
        // try the next server
      }
    }
    return const [];
  }

  /// One query: the reply and the query id, or null when this server gave
  /// no answer.
  Future<(Uint8List, int)?> _query(
    InternetAddress server,
    String name,
    int type,
  ) async {
    final id = _random.nextInt(0x10000);
    final socket = await RawDatagramSocket.bind(
      server.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    try {
      socket.send(DnsMessage.query(id, name, type), server, 53);
      final completer = Completer<Uint8List?>();
      final subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        // Accept only answers from the server we asked.
        if (datagram == null ||
            datagram.address != server ||
            datagram.port != 53) {
          return;
        }
        if (!completer.isCompleted) completer.complete(datagram.data);
      });
      try {
        final data = await completer.future.timeout(
          timeout,
          onTimeout: () => null,
        );
        return data == null ? null : (data, id);
      } finally {
        await subscription.cancel();
      }
    } finally {
      socket.close();
    }
  }
}

/// DNS message encoding and decoding for SRV and MX queries.
abstract final class DnsMessage {
  static Uint8List query(int id, String name, int type) {
    final out = BytesBuilder();
    out.add([
      id >> 8,
      id & 0xFF,
      0x01,
      0x00,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
    ]); // RD, 1 question
    out.add(_encodeName(name));
    out.add([type >> 8, type & 0xFF, 0, 1]); // class IN
    return out.takeBytes();
  }

  /// The SRV records in [data], checking it answers our query [id] for
  /// [name]. Returns an empty list for "no such name"; throws
  /// [FormatException] for anything malformed or unexpected.
  static List<SrvRecord> parseSrvAnswer(Uint8List data, int id, String name) {
    final records = <SrvRecord>[];
    _answers(data, id, name, (type, length, reader) {
      if (type == 33 && length >= 7) {
        final priority = reader.u16(),
            weight = reader.u16(),
            port = reader.u16();
        final target = reader.name();
        // "." means the service is explicitly not offered (RFC 2782).
        if (target.isNotEmpty && port > 0) {
          records.add(SrvRecord(priority, weight, port, target.toLowerCase()));
        }
      }
    });
    return records;
  }

  /// The MX records in [data], checked like [parseSrvAnswer]. A null MX
  /// ("." , RFC 7505: no mail accepted) is left out.
  static List<MxRecord> parseMxAnswer(Uint8List data, int id, String name) {
    final records = <MxRecord>[];
    _answers(data, id, name, (type, length, reader) {
      if (type == 15 && length >= 3) {
        final preference = reader.u16();
        final exchange = reader.name();
        if (exchange.isNotEmpty) {
          records.add(MxRecord(preference, exchange.toLowerCase()));
        }
      }
    });
    return records;
  }

  /// Checks the header and question, then hands each answer's type,
  /// data length and a reader at its data to [onAnswer].
  static void _answers(
    Uint8List data,
    int id,
    String name,
    void Function(int type, int length, _Reader reader) onAnswer,
  ) {
    if (data.length < 12) throw const FormatException('DNS reply too short');
    final reader = _Reader(data);
    if (reader.u16() != id) {
      throw const FormatException('DNS reply for another query');
    }
    final flags = reader.u16();
    if (flags & 0x8000 == 0) throw const FormatException('not a DNS reply');
    final rcode = flags & 0x000F;
    if (rcode == 3) return; // NXDOMAIN
    if (rcode != 0) throw FormatException('DNS error $rcode');
    final questions = reader.u16(), answers = reader.u16();
    reader.u16(); // authority
    reader.u16(); // additional
    if (questions != 1) {
      throw const FormatException('unexpected DNS question count');
    }
    final asked = reader.name();
    if (asked.toLowerCase() !=
        name.toLowerCase().replaceAll(RegExp(r'\.$'), '')) {
      throw const FormatException('DNS reply for another name');
    }
    reader.skip(4);
    for (var i = 0; i < answers && i < 50; i++) {
      reader.name();
      final type = reader.u16();
      reader.skip(6); // class, TTL
      final length = reader.u16();
      final end = reader.position + length;
      if (end > data.length) throw const FormatException('DNS reply truncated');
      onAnswer(type, length, reader);
      reader.position = end;
    }
  }

  static Uint8List _encodeName(String name) {
    final out = BytesBuilder();
    for (final label in name.split('.').where((l) => l.isNotEmpty)) {
      if (label.length > 63 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(label)) {
        throw ArgumentError.value(name, 'name', 'not a valid DNS name');
      }
      out
        ..addByte(label.length)
        ..add(label.codeUnits);
    }
    out.addByte(0);
    return out.takeBytes();
  }
}

final class _Reader {
  _Reader(this.data);

  final Uint8List data;
  int position = 0;

  int u16() {
    if (position + 2 > data.length) {
      throw const FormatException('DNS reply truncated');
    }
    final value = (data[position] << 8) | data[position + 1];
    position += 2;
    return value;
  }

  void skip(int n) {
    if (position + n > data.length) {
      throw const FormatException('DNS reply truncated');
    }
    position += n;
  }

  /// A possibly compressed name; follows at most 10 pointers (loop guard).
  String name() {
    final labels = <String>[];
    var at = position;
    var jumped = false;
    for (var jumps = 0; jumps <= 10;) {
      if (at >= data.length) throw const FormatException('DNS name truncated');
      final length = data[at];
      if (length == 0) {
        if (!jumped) position = at + 1;
        return labels.join('.');
      }
      if (length & 0xC0 == 0xC0) {
        if (at + 1 >= data.length) {
          throw const FormatException('DNS pointer truncated');
        }
        if (!jumped) position = at + 2;
        at = ((length & 0x3F) << 8) | data[at + 1];
        jumped = true;
        jumps++;
        continue;
      }
      if (at + 1 + length > data.length) {
        throw const FormatException('DNS label truncated');
      }
      labels.add(String.fromCharCodes(data, at + 1, at + 1 + length));
      at += 1 + length;
    }
    throw const FormatException('DNS name compression loop');
  }
}
