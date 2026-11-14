// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_ai/src/providers/http_errors.dart';
import 'package:mail_ai/src/providers/sse.dart';
import 'package:test/test.dart';

void main() {
  test('server-sent events, split anywhere', () async {
    const text =
        ': a comment\r\n'
        'event: message_start\r\n'
        'data: {"a":1}\r\n'
        '\r\n'
        'data: line one\n'
        'data:line two\n'
        '\n'
        'event: ping\n'
        '\n'
        'data: last';
    final bytes = utf8.encode(text);
    // Arrives in pieces of three bytes.
    final pieces = [
      for (var i = 0; i < bytes.length; i += 3)
        bytes.sublist(i, (i + 3).clamp(0, bytes.length)),
    ];
    final events = await parseSse(Stream.fromIterable(pieces)).toList();
    expect(events.map((e) => (e.event, e.data)), [
      ('message_start', '{"a":1}'),
      (null, 'line one\nline two'),
      (null, 'last'),
    ]);
  });

  test('an event too large is refused', () {
    expect(
      parseSse(
        Stream.value(utf8.encode('data: ${'x' * 100}\n\n')),
        maxEventBytes: 50,
      ).toList(),
      throwsFormatException,
    );
  });

  test('retry-after in seconds, milliseconds or as a date', () {
    expect(retryAfter({'retry-after': '20'}), const Duration(seconds: 20));
    expect(
      retryAfter({'retry-after-ms': '250', 'retry-after': '1'}),
      const Duration(milliseconds: 250),
    );
    expect(
      retryAfter({
        'retry-after': 'Sat, 14 Nov 2026 10:01:00 GMT',
      }, now: DateTime.utc(2026, 11, 14, 10)),
      const Duration(minutes: 1),
    );
    expect(retryAfter({'retry-after': 'soon'}), isNull);
    expect(retryAfter({}), isNull);
  });
}
