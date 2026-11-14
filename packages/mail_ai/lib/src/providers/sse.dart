// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// One server-sent event.
final class SseEvent {
  const SseEvent(this.event, this.data);

  /// The `event:` name, or null.
  final String? event;

  /// The `data:` lines, joined with line breaks.
  final String data;
}

/// Server-sent events from a response body
/// (https://html.spec.whatwg.org/multipage/server-sent-events.html):
/// `event:` and `data:` fields, an empty line ends an event, `:` lines
/// are comments. One event's data may be at most [maxEventBytes].
Stream<SseEvent> parseSse(
  Stream<List<int>> body, {
  int maxEventBytes = 1024 * 1024,
}) async* {
  String? event;
  final data = <String>[];
  var size = 0;
  await for (final line
      in body.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
      event = null;
      data.clear();
      size = 0;
      continue;
    }
    if (line.startsWith(':')) continue;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        size += value.length;
        if (size > maxEventBytes) {
          throw const FormatException('event too large');
        }
        data.add(value);
    }
  }
  if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
}
