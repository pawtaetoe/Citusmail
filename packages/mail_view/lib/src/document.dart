// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// A message body reduced to what is safe to show: text with simple
/// structure, links, and images that are already inside the message.
///
/// There is deliberately no way to express a remote resource here, so a
/// renderer of this model cannot make network requests.
final class RichDocument {
  const RichDocument(
    this.blocks, {
    this.blockedImages = 0,
    this.truncated = false,
  });

  static const empty = RichDocument([]);

  final List<Block> blocks;

  /// Remote images left out (including tracking pixels).
  final int blockedImages;

  /// Parts were left out because the message was too large or too deeply
  /// nested to show safely.
  final bool truncated;

  /// The text of the document, for search and previews.
  String get plainText {
    final out = StringBuffer();
    void writeBlocks(List<Block> blocks) {
      for (final block in blocks) {
        switch (block) {
          case ParagraphBlock(:final inlines) || HeadingBlock(:final inlines):
            for (final inline in inlines) {
              switch (inline) {
                case TextRun(:final text):
                  out.write(text);
                case LineBreak():
                  out.write('\n');
                case ImageInline(:final alt):
                  if (alt.isNotEmpty) out.write(alt);
              }
            }
            out.write('\n');
          case QuoteBlock(:final children):
            writeBlocks(children);
          case ListBlock(:final items):
            for (final item in items) {
              writeBlocks(item);
            }
          case PreformattedBlock(:final text):
            out
              ..write(text)
              ..write('\n');
          case TableBlock(:final rows):
            for (final row in rows) {
              for (final cell in row) {
                writeBlocks(cell.blocks);
              }
            }
          case RuleBlock():
            break;
        }
      }
    }

    writeBlocks(blocks);
    return out.toString();
  }
}

/// A block-level piece of the document.
sealed class Block {
  const Block();
}

final class ParagraphBlock extends Block {
  const ParagraphBlock(this.inlines);

  final List<Inline> inlines;
}

final class HeadingBlock extends Block {
  const HeadingBlock(this.level, this.inlines);

  /// 1 to 6.
  final int level;
  final List<Inline> inlines;
}

/// Quoted text (`<blockquote>`, or `>` lines in plain text).
final class QuoteBlock extends Block {
  const QuoteBlock(this.children);

  final List<Block> children;
}

final class ListBlock extends Block {
  const ListBlock({required this.ordered, required this.items});

  final bool ordered;

  /// Each item is a list of blocks.
  final List<List<Block>> items;
}

/// Text shown exactly as written, in a fixed-width font.
final class PreformattedBlock extends Block {
  const PreformattedBlock(this.text);

  final String text;
}

/// A horizontal line.
final class RuleBlock extends Block {
  const RuleBlock();
}

/// A data table (one with header cells). Layout tables are flattened
/// into ordinary blocks instead, which reads better on narrow screens.
final class TableBlock extends Block {
  const TableBlock(this.rows);

  final List<List<TableCell>> rows;
}

final class TableCell {
  const TableCell(this.blocks, {this.header = false});

  final List<Block> blocks;
  final bool header;
}

/// Inline content of a paragraph or heading.
sealed class Inline {
  const Inline();
}

/// Text with a style and, optionally, a link.
final class TextRun extends Inline {
  const TextRun(this.text, {this.style = TextStyleFlags.none, this.link});

  final String text;
  final TextStyleFlags style;

  /// Only `http`, `https` and `mailto` links are kept.
  final Uri? link;
}

final class LineBreak extends Inline {
  const LineBreak();
}

/// An image that is part of the message itself (a `cid:` attachment or a
/// `data:` URI). Remote images never become one of these.
final class ImageInline extends Inline {
  const ImageInline(
    this.bytes, {
    required this.mimeType,
    this.alt = '',
    this.width,
    this.height,
    this.link,
  });

  final Uint8List bytes;

  /// `image/png`, `image/jpeg`, `image/gif` or `image/webp`.
  final String mimeType;
  final String alt;

  /// Size hints from the HTML, in logical pixels.
  final double? width;
  final double? height;
  final Uri? link;
}

/// Text styles as flags.
final class TextStyleFlags {
  const TextStyleFlags({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
  });

  static const none = TextStyleFlags();

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;

  TextStyleFlags copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? code,
  }) => TextStyleFlags(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    code: code ?? this.code,
  );

  @override
  bool operator ==(Object other) =>
      other is TextStyleFlags &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.code == code;

  @override
  int get hashCode => Object.hash(bold, italic, underline, strike, code);
}

/// Which links may be shown as links. Everything else (`javascript:`,
/// `file:`, `data:`, app schemes...) becomes plain text.
abstract final class SafeLinks {
  static const schemes = {'http', 'https', 'mailto'};

  static Uri? parse(String? href) {
    if (href == null) return null;
    final trimmed = href.trim();
    if (trimmed.isEmpty || trimmed.length > 4096) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !schemes.contains(uri.scheme.toLowerCase())) {
      return null;
    }
    if (uri.scheme.toLowerCase() != 'mailto' && uri.host.isEmpty) return null;
    return uri;
  }
}
