// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_appsync/mail_appsync.dart';
import 'package:test/test.dart';

SyncRecord _r(
  String key, {
  required int at,
  String device = 'a',
  bool deleted = false,
  Map<String, Object?> data = const {'x': 1},
}) => SyncRecord(
  key: key,
  kind: RecordKind.block,
  changedAt: at,
  device: device,
  data: data,
  deleted: deleted,
);

void main() {
  group('SyncCode', () {
    test('round-trips, 27 characters in groups of four', () {
      final code = SyncCode.generate(Random(1));
      final text = code.toString();
      expect(
        text,
        matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){6}[0-9A-HJKMNP-TV-Z]{3}$')),
      );
      expect(SyncCode.parse(text), code);
    });

    test('reading is forgiving about case, spaces and lookalikes', () {
      final code = SyncCode.generate(Random(2));
      final text = code.toString();
      final sloppy = text
          .toLowerCase()
          .replaceAll('-', ' ')
          .replaceAll('0', 'o')
          .replaceAll('1', 'l');
      expect(SyncCode.parse(sloppy), code);
    });

    test('typing mistakes are caught', () {
      final text = SyncCode.generate(Random(3)).toString();
      final chars = text.split('');
      var caught = 0;
      for (var i = 0; i < chars.length; i++) {
        if (chars[i] == '-') continue;
        final wrong = [...chars]..[i] = chars[i] == 'A' ? 'B' : 'A';
        if (SyncCode.parse(wrong.join()) == null) caught++;
      }
      expect(caught, greaterThanOrEqualTo(20), reason: 'the check char');
      expect(SyncCode.parse(text.substring(1)), isNull);
      expect(SyncCode.parse('${text}X'), isNull);
      expect(SyncCode.parse('UUUU-UUUU-UUUU-UUUU-UUUU-UUUU-UUU'), isNull);
      expect(SyncCode.parse(''), isNull);
    });

    test('keys differ per code and are stable', () {
      final a = SyncCode.generate(Random(4));
      final b = SyncCode.generate(Random(5));
      expect(a.keys.encryptionKey, hasLength(32));
      expect(a.keys.syncId, hasLength(32));
      expect(a.keys.syncId, SyncCode.parse(a.toString())!.keys.syncId);
      expect(a.keys.syncId, isNot(b.keys.syncId));
      expect(a.keys.encryptionKey, isNot(b.keys.encryptionKey));
    });
  });

  group('merging', () {
    test('the later change wins, deletions included', () {
      final merged = SyncSnapshot.merge([
        SyncSnapshot(
          device: 'a',
          createdAt: 0,
          records: [
            _r('k1', at: 10),
            _r('k2', at: 10),
            _r('k3', at: 30, deleted: true),
          ],
        ),
        SyncSnapshot(
          device: 'b',
          createdAt: 0,
          records: [
            _r('k1', at: 20, device: 'b', data: {'x': 2}),
            _r('k2', at: 15, device: 'b', deleted: true),
            _r('k3', at: 20, device: 'b'),
            _r('k4', at: 5, device: 'b'),
          ],
        ),
      ]);
      expect(merged['k1']!.data['x'], 2);
      expect(merged['k2']!.deleted, isTrue);
      expect(merged['k3']!.deleted, isTrue, reason: 'deleted later');
      expect(merged['k4']!.device, 'b');
    });

    test('ties are decided the same way on every device', () {
      final add = _r('k', at: 10, device: 'a');
      final remove = _r('k', at: 10, device: 'b', deleted: true);
      expect(SyncRecord.newer(add, remove).deleted, isTrue);
      expect(SyncRecord.newer(remove, add).deleted, isTrue);
      final x = _r('k', at: 10, device: 'x', data: {'v': 'x'});
      final y = _r('k', at: 10, device: 'y', data: {'v': 'y'});
      expect(SyncRecord.newer(x, y), same(y));
      expect(SyncRecord.newer(y, x), same(y));
    });
  });

  group('SnapshotSealer', () {
    final keys = SyncCode.generate(Random(6)).keys;
    final snapshot = SyncSnapshot(
      device: 'device-1',
      createdAt: 1761300000000,
      records: [
        _r('block:address:news@shop.example', at: 5, device: 'device-1'),
        _r('images:a@b.example', at: 6, device: 'device-1', deleted: true),
      ],
    );

    test('seal and open', () {
      final sealed = SnapshotSealer(keys).seal(snapshot);
      expect(ascii.decode(sealed.sublist(0, 7)), 'CMSYNC1');
      expect(
        utf8.decode(sealed, allowMalformed: true),
        isNot(contains('news@shop')),
      );
      final opened = SnapshotSealer(keys).open(sealed, device: 'device-1');
      expect(opened.createdAt, snapshot.createdAt);
      expect(
        opened.records.map((r) => r.key),
        snapshot.records.map((r) => r.key),
      );
      expect(opened.records.last.deleted, isTrue);
      expect(opened.records.first.data, {'x': 1});
    });

    test('a fresh nonce every time', () {
      final a = SnapshotSealer(keys).seal(snapshot);
      final b = SnapshotSealer(keys).seal(snapshot);
      expect(a.sublist(7, 19), isNot(b.sublist(7, 19)));
    });

    test('another code, another device or a change is refused', () {
      final sealed = SnapshotSealer(keys).seal(snapshot);
      final otherKeys = SyncCode.generate(Random(7)).keys;
      expect(
        () => SnapshotSealer(otherKeys).open(sealed, device: 'device-1'),
        throwsA(isA<AuthenticationFailed>()),
      );
      expect(
        () => SnapshotSealer(keys).open(sealed, device: 'device-2'),
        throwsA(isA<AuthenticationFailed>()),
        reason: 'stored under another device id',
      );
      final bent = Uint8List.fromList(sealed)..[30] ^= 1;
      expect(
        () => SnapshotSealer(keys).open(bent, device: 'device-1'),
        throwsA(isA<AuthenticationFailed>()),
      );
      expect(
        () => SnapshotSealer(keys)
            .open(Uint8List.fromList(utf8.encode('hello')), device: 'device-1'),
        throwsFormatException,
      );
    });
  });

  test('records reject junk', () {
    for (final json in [
      null,
      'x',
      {'k': 'a'},
      {'k': 'a', 't': 'nope', 'at': 1, 'dev': 'd'},
      {'k': 1, 't': 'block', 'at': 1, 'dev': 'd'},
      {'k': 'a', 't': 'block', 'at': '1', 'dev': 'd'},
    ]) {
      expect(
        () => SyncRecord.fromJson(json),
        throwsFormatException,
        reason: '$json',
      );
    }
    expect(() => _r('', at: 1), throwsArgumentError);
    expect(() => _r('x' * 601, at: 1), throwsArgumentError);
  });
}
