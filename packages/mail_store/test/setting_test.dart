// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

enum _Shade { light, dark, system }

final class _Point {
  const _Point(this.x, this.y);

  final int x;
  final int y;

  static _Point? fromJson(Object? json) => switch (json) {
    {'x': final int x, 'y': final int y} => _Point(x, y),
    _ => null,
  };

  static Object? toJson(_Point p) => {'x': p.x, 'y': p.y};

  @override
  bool operator ==(Object other) =>
      other is _Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

void main() {
  late TempStore temp;
  SettingsRepository settings() => temp.store.settings;

  setUp(() => temp = TempStore.create());
  tearDown(() => temp.dispose());

  group('Setting', () {
    const setting = IntSetting('test.count', fallback: 3);

    test('reads its fallback when nothing is stored', () {
      expect(setting.read(settings()), 3);
      expect(setting.readOrNull(settings()), isNull);
      expect(setting.isSetIn(settings()), isFalse);
    });

    test('writes, reads and clears under its key', () {
      setting.write(settings(), 7);
      expect(settings().read('test.count'), '7');
      expect(setting.read(settings()), 7);
      expect(setting.readOrNull(settings()), 7);
      expect(setting.isSetIn(settings()), isTrue);
      setting.clear(settings());
      expect(settings().read('test.count'), isNull);
      expect(setting.read(settings()), 3);
    });

    test('an unreadable value reads as the fallback and is kept', () {
      settings().write('test.count', 'many');
      expect(setting.read(settings()), 3);
      expect(setting.readOrNull(settings()), isNull);
      expect(setting.isSetIn(settings()), isTrue);
      expect(settings().read('test.count'), 'many');
    });

    test('decode and encode', () {
      expect(setting.decode('12'), 12);
      expect(setting.decode('x'), 3);
      expect(setting.encode(12), '12');
    });

    test('a synced setting written through it is still noted', () {
      final at = DateTime.utc(2026, 11, 9, 9);
      const reminders = BoolSetting('reminders.on', fallback: true);
      reminders.write(settings(), false, at: at);
      expect(
        SyncedPreferences(temp.store.database).changedAt(reminders.key),
        at,
      );
    });
  });

  group('BoolSetting', () {
    const onByDefault = BoolSetting('test.on', fallback: true);
    const offByDefault = BoolSetting('test.off');

    test('round trips as on and off', () {
      for (final value in [true, false]) {
        onByDefault.write(settings(), value);
        expect(onByDefault.read(settings()), value);
      }
      onByDefault.write(settings(), true);
      expect(settings().read('test.on'), 'on');
      onByDefault.write(settings(), false);
      expect(settings().read('test.on'), 'off');
    });

    test('defaults', () {
      expect(onByDefault.read(settings()), isTrue);
      expect(offByDefault.read(settings()), isFalse);
    });

    test('anything but on or off reads as the default', () {
      // As the old code read them: `!= 'off'` and `== 'on'`.
      for (final stored in ['', 'yes', 'true', 'ON', '1']) {
        settings().write('test.on', stored);
        settings().write('test.off', stored);
        expect(onByDefault.read(settings()), stored != 'off', reason: stored);
        expect(offByDefault.read(settings()), stored == 'on', reason: stored);
      }
    });

    test('other words for on and off', () {
      const asked = BoolSetting('test.asked', onText: 'yes', offText: 'no');
      asked.write(settings(), true);
      expect(settings().read('test.asked'), 'yes');
      expect(asked.read(settings()), isTrue);
      settings().write('test.asked', 'on');
      expect(asked.read(settings()), isFalse);
    });
  });

  group('IntSetting', () {
    const bounded = IntSetting('test.n', fallback: 25, min: 1, max: 200);

    test('round trips', () {
      for (final value in [1, 25, 200]) {
        bounded.write(settings(), value);
        expect(settings().read('test.n'), '$value');
        expect(bounded.read(settings()), value);
      }
      const free = IntSetting('test.free');
      for (final value in [-5, 0, 1 << 40]) {
        free.write(settings(), value);
        expect(free.read(settings()), value);
      }
    });

    test('out of bounds or unreadable reads as the fallback', () {
      for (final stored in ['0', '201', '-3', '', 'ten', '1.5']) {
        settings().write('test.n', stored);
        expect(bounded.read(settings()), 25, reason: stored);
        expect(bounded.readOrNull(settings()), isNull, reason: stored);
      }
    });

    test('a write out of bounds is clamped', () {
      bounded.write(settings(), 500);
      expect(settings().read('test.n'), '200');
      bounded.write(settings(), -1);
      expect(settings().read('test.n'), '1');
    });
  });

  group('EnumSetting', () {
    const shade = EnumSetting(
      'test.shade',
      _Shade.values,
      fallback: _Shade.system,
    );

    test('round trips by name', () {
      for (final value in _Shade.values) {
        shade.write(settings(), value);
        expect(settings().read('test.shade'), value.name);
        expect(shade.read(settings()), value);
      }
    });

    test('an unknown name reads as the fallback', () {
      expect(shade.read(settings()), _Shade.system);
      for (final stored in ['', 'Dark', 'sepia']) {
        settings().write('test.shade', stored);
        expect(shade.read(settings()), _Shade.system, reason: stored);
      }
    });
  });

  group('StringSetting', () {
    const name = StringSetting('test.name');

    test('round trips any text', () {
      for (final value in ['', 'plain', 'with, commas\nand lines', 'ü✓']) {
        name.write(settings(), value);
        expect(settings().read('test.name'), value);
        expect(name.read(settings()), value);
      }
    });

    test('defaults', () {
      expect(name.read(settings()), '');
      expect(name.readOrNull(settings()), isNull);
      expect(
        const StringSetting('test.other', fallback: 'x').read(settings()),
        'x',
      );
    });
  });

  group('DateTimeSetting', () {
    const at = DateTimeSetting('test.at');
    final monday = DateTime.utc(2026, 11, 9, 9, 30, 15, 250);

    test('round trips as milliseconds, read back in UTC', () {
      at.write(settings(), monday);
      expect(settings().read('test.at'), '${monday.millisecondsSinceEpoch}');
      expect(at.read(settings()), monday);
      expect(at.read(settings())!.isUtc, isTrue);
      at.write(settings(), monday.toLocal());
      expect(at.read(settings()), monday);
    });

    test('as ISO-8601 in UTC', () {
      const iso = DateTimeSetting('test.iso', format: DateTimeFormat.iso8601);
      iso.write(settings(), monday.toLocal());
      expect(settings().read('test.iso'), '2026-11-09T09:30:15.250Z');
      expect(iso.read(settings()), monday);
      settings().write('test.iso', 'last week');
      expect(iso.read(settings()), isNull);
    });

    test('nothing, empty or unreadable is null', () {
      expect(at.read(settings()), isNull);
      at.write(settings(), null);
      expect(settings().read('test.at'), '');
      expect(at.read(settings()), isNull);
      settings().write('test.at', 'soon');
      expect(at.read(settings()), isNull);
    });
  });

  group('StringListSetting', () {
    const list = StringListSetting('test.list');
    const lines = StringListSetting('test.lines', separator: '\n');

    test('round trips, joined as before', () {
      list.write(settings(), ['a', 'b@c.example', 'd']);
      expect(settings().read('test.list'), 'a,b@c.example,d');
      expect(list.read(settings()), ['a', 'b@c.example', 'd']);
      lines.write(settings(), ['one, two', 'three']);
      expect(settings().read('test.lines'), 'one, two\nthree');
      expect(lines.read(settings()), ['one, two', 'three']);
    });

    test('empty items are left out; an empty list is empty text', () {
      settings().write('test.list', ',a,,b,');
      expect(list.read(settings()), ['a', 'b']);
      list.write(settings(), []);
      expect(settings().read('test.list'), '');
      expect(list.read(settings()), isEmpty);
      expect(list.isSetIn(settings()), isTrue);
    });

    test('defaults to empty', () {
      expect(list.read(settings()), isEmpty);
    });
  });

  group('JsonSetting', () {
    const point = JsonSetting<_Point>(
      'test.point',
      fallback: _Point(0, 0),
      fromJson: _Point.fromJson,
      toJson: _Point.toJson,
    );

    test('round trips as JSON', () {
      point.write(settings(), const _Point(3, 4));
      expect(settings().read('test.point'), '{"x":3,"y":4}');
      expect(point.read(settings()), const _Point(3, 4));
    });

    test('not JSON, or the wrong shape, reads as the fallback', () {
      for (final stored in ['', '{', '[1,2]', '{"x":"3","y":4}', 'null']) {
        settings().write('test.point', stored);
        expect(point.read(settings()), const _Point(0, 0), reason: stored);
      }
    });

    test('a throwing decoder reads as the fallback', () {
      final strict = JsonSetting<List<int>>(
        'test.ints',
        fallback: const [],
        fromJson: (json) => (json! as List<Object?>).cast<int>().toList(),
        toJson: (v) => v,
      );
      settings().write('test.ints', '[1,"two"]');
      expect(strict.read(settings()), isEmpty);
      settings().write('test.ints', '"text"');
      expect(strict.read(settings()), isEmpty);
      strict.write(settings(), [1, 2]);
      expect(settings().read('test.ints'), '[1,2]');
      expect(strict.read(settings()), [1, 2]);
    });
  });
}
