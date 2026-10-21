// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'document.dart';

/// Converts a plain-text body into a [RichDocument]: paragraphs, `>`
/// quotes as quote blocks, and web and mail addresses as links.
final class PlainTextConverter {
  const PlainTextConverter({this.maxLength = 2000000});

  /// Longer text is cut (and the document marked truncated).
  final int maxLength;

  /// [flowed] and [delSp] follow the `format=flowed` and `delsp=yes`
  /// Content-Type parameters (RFC 3676).
  RichDocument convert(String text, {bool flowed = false, bool delSp = false}) {
    final truncated = text.length > maxLength;
    final body = (truncated ? text.substring(0, maxLength) : text)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final lines = _QuotedLine.split(body);
    final joined = flowed ? _unflow(lines, delSp: delSp) : lines;
    return RichDocument(_blocks(joined, 0), truncated: truncated);
  }

  /// Joins soft-broken lines: in format=flowed a line ending in a space
  /// continues on the next line of the same quote depth.
  static List<_QuotedLine> _unflow(
    List<_QuotedLine> lines, {
    required bool delSp,
  }) {
    final result = <_QuotedLine>[];
    for (final line in lines) {
      // Space-stuffing: the sender added one leading space (for quoted
      // lines it was already removed with the quote marks).
      final text = line.depth == 0 && line.text.startsWith(' ')
          ? line.text.substring(1)
          : line.text;
      final previous = result.isEmpty ? null : result.last;
      if (previous != null &&
          previous.depth == line.depth &&
          previous.text.endsWith(' ') &&
          previous.text != '-- ') {
        final kept = delSp
            ? previous.text.substring(0, previous.text.length - 1)
            : previous.text;
        result[result.length - 1] = _QuotedLine(line.depth, kept + text);
      } else {
        result.add(_QuotedLine(line.depth, text));
      }
    }
    return result;
  }

  /// Lines at [depth] become paragraphs; deeper runs become quotes.
  static List<Block> _blocks(List<_QuotedLine> lines, int depth) {
    final blocks = <Block>[];
    final paragraph = <String>[];

    void endParagraph() {
      if (paragraph.isEmpty) return;
      final inlines = <Inline>[];
      for (var i = 0; i < paragraph.length; i++) {
        if (i > 0) inlines.add(const LineBreak());
        inlines.addAll(_linkify(paragraph[i]));
      }
      blocks.add(ParagraphBlock(List.unmodifiable(inlines)));
      paragraph.clear();
    }

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.depth > depth) {
        endParagraph();
        final quoted = <_QuotedLine>[];
        while (i < lines.length && lines[i].depth > depth) {
          quoted.add(lines[i]);
          i++;
        }
        final inner = _blocks(quoted, depth + 1);
        if (inner.isNotEmpty) blocks.add(QuoteBlock(List.unmodifiable(inner)));
        continue;
      }
      if (line.text.trim().isEmpty) {
        endParagraph();
      } else {
        paragraph.add(line.text.trimRight());
      }
      i++;
    }
    endParagraph();
    return blocks;
  }

  /// Splits text into runs, turning web and mail addresses into links.
  static List<Inline> _linkify(String text) {
    final runs = <Inline>[];
    var position = 0;
    for (final match in _links.allMatches(text)) {
      var candidate = match.group(0)!;
      // Trailing punctuation usually ends the sentence, not the link.
      while (candidate.isNotEmpty &&
          '.,;:!?\'")]>'.contains(candidate[candidate.length - 1])) {
        candidate = candidate.substring(0, candidate.length - 1);
      }
      final href = candidate.toLowerCase().startsWith('www.')
          ? 'https://$candidate'
          : candidate.contains('@') &&
                !candidate.contains('://') &&
                !candidate.toLowerCase().startsWith('mailto:')
          ? 'mailto:$candidate'
          : candidate;
      final link = SafeLinks.parse(href);
      if (link == null) continue;
      if (match.start > position) {
        runs.add(TextRun(text.substring(position, match.start)));
      }
      runs.add(TextRun(candidate, link: link));
      position = match.start + candidate.length;
    }
    if (position < text.length) runs.add(TextRun(text.substring(position)));
    return runs;
  }

  static final _links = RegExp(
    r'''(?:https?://|mailto:|www\.)[^\s<>"]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+''',
    caseSensitive: false,
  );
}

/// A line with its quote depth (number of leading `>`).
final class _QuotedLine {
  const _QuotedLine(this.depth, this.text);

  final int depth;
  final String text;

  static List<_QuotedLine> split(String body) => [
    for (final line in body.split('\n')) _parse(line),
  ];

  static _QuotedLine _parse(String line) {
    var depth = 0;
    var i = 0;
    while (i < line.length && line[i] == '>') {
      depth++;
      i++;
      // "> > text" is also depth 2.
      if (i + 1 < line.length && line[i] == ' ' && line[i + 1] == '>') i++;
    }
    var text = line.substring(i);
    if (depth > 0 && text.startsWith(' ')) text = text.substring(1);
    return _QuotedLine(depth, text);
  }
}
