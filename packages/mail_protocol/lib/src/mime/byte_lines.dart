// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// One line in a byte buffer.
///
/// [start] is the first byte, [contentEnd] is just after the last content
/// byte (before CR LF or LF), and [end] is just after the line ending
/// (equal to [contentEnd] on the last line if it has no line ending).
final class ByteLine {
  const ByteLine(this.start, this.contentEnd, this.end);

  final int start;
  final int contentEnd;
  final int end;

  bool get isEmpty => contentEnd == start;
  int get contentLength => contentEnd - start;
}

/// Iterates over lines in `bytes[start, end)`, accepting CRLF and bare LF.
/// A bare CR is treated as ordinary content, as most mail software does.
Iterable<ByteLine> byteLines(List<int> bytes, int start, int end) sync* {
  var i = start;
  while (i < end) {
    var newline = i;
    while (newline < end && bytes[newline] != 0x0A) {
      newline++;
    }
    if (newline == end) {
      yield ByteLine(i, end, end);
      return;
    }
    final contentEnd = newline > i && bytes[newline - 1] == 0x0D
        ? newline - 1
        : newline;
    yield ByteLine(i, contentEnd, newline + 1);
    i = newline + 1;
  }
}
