// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'document.dart';
import 'image_header.dart';
import 'trackers.dart';

/// An image part of the message, found by its Content-ID.
typedef ContentIdImage = ({Uint8List bytes, String mimeType});

/// Looks up `cid:` images; returns null if there is no such image part.
typedef ContentIdResolver = ContentIdImage? Function(String contentId);

/// Bounds that keep hostile HTML from using too much time or memory.
final class HtmlConverterLimits {
  const HtmlConverterLimits({
    this.maxDepth = 100,
    this.maxBlocks = 20000,
    this.maxTextLength = 2000000,
    this.maxImageBytes = 5 * 1024 * 1024,
    this.maxTableCells = 5000,
    this.maxSourceLength = 5000000,
    this.maxRemoteImages = 200,
  });

  /// Remote images beyond this many are left out (still counted).
  final int maxRemoteImages;

  /// HTML longer than this is cut before parsing.
  final int maxSourceLength;

  /// Elements nested deeper are left out (and the document is marked
  /// truncated).
  final int maxDepth;
  final int maxBlocks;
  final int maxTextLength;

  /// Embedded images larger than this are left out.
  final int maxImageBytes;

  /// Data tables with more cells are flattened instead.
  final int maxTableCells;
}

/// Converts email HTML into a [RichDocument] with an allow-list: text,
/// simple structure, safe links and images embedded in the message.
///
/// Everything that could run code or reach the network is dropped:
/// scripts, styles, frames, forms, objects, SVG, remote images, CSS (so no
/// background images or fonts), and links with unsafe schemes. Content
/// hidden with `display:none` or `hidden` is left out, so hidden text
/// cannot be revealed to mislead the reader.
final class HtmlConverter {
  const HtmlConverter({this.limits = const HtmlConverterLimits()});

  final HtmlConverterLimits limits;

  RichDocument convert(String source, {ContentIdResolver? resolveContentId}) {
    final tooLong = source.length > limits.maxSourceLength;
    final document = html.parse(
      tooLong ? source.substring(0, limits.maxSourceLength) : source,
    );
    final converter = _Conversion(limits, resolveContentId)
      ..truncated = tooLong;
    final root = _Sink();
    try {
      converter.walkChildren(
        document.documentElement ?? document,
        root,
        const _Context(),
      );
      root.flush(converter);
    } on _LimitReached {
      converter.truncated = true; // keep what was converted so far
    }
    return RichDocument(
      List.unmodifiable(root.blocks),
      remoteImages: converter.remoteImages,
      trackers: converter.trackers,
      trackerHosts: Set.unmodifiable(converter.trackerHosts),
      truncated: converter.truncated,
    );
  }
}

/// Thrown internally when a limit is reached; the work done so far is kept.
final class _LimitReached implements Exception {
  const _LimitReached();
}

/// Inherited formatting while walking the tree.
final class _Context {
  const _Context({this.style = TextStyleFlags.none, this.link, this.depth = 0});

  final TextStyleFlags style;
  final Uri? link;
  final int depth;

  _Context deeper({TextStyleFlags? style, Uri? link, bool keepLink = true}) =>
      _Context(
        style: style ?? this.style,
        link: link ?? (keepLink ? this.link : null),
        depth: depth + 1,
      );
}

/// Collects blocks, and the inline content of the paragraph being built.
final class _Sink {
  final blocks = <Block>[];
  final _inlines = <Inline>[];
  bool _spaceWanted = false;

  bool get _hasContent => _inlines.any(
    (i) =>
        i is ImageInline ||
        i is RemoteImageInline ||
        (i is TextRun && i.text.trim().isNotEmpty),
  );

  void addText(String text, _Context context) {
    final collapsed = text.replaceAll(_whitespace, ' ');
    if (collapsed.isEmpty) return;
    if (collapsed.startsWith(' ')) _spaceWanted = true;
    final words = collapsed.trim();
    if (words.isEmpty) return;
    final needsSpace = _spaceWanted && _inlines.isNotEmpty && !_endsWithBreak;
    _append(
      TextRun(
        needsSpace ? ' $words' : words,
        style: context.style,
        link: context.link,
      ),
    );
    _spaceWanted = collapsed.endsWith(' ');
  }

  /// Text that keeps its spaces and line breaks (inside `<pre>`).
  void addRaw(String text, _Context context) =>
      _append(TextRun(text, style: context.style, link: context.link));

  void addInline(Inline inline) {
    if ((inline is ImageInline || inline is RemoteImageInline) &&
        _spaceWanted &&
        _inlines.isNotEmpty) {
      _append(const TextRun(' '));
    }
    _inlines.add(inline);
    _spaceWanted = false;
  }

  void lineBreak() {
    _inlines.add(const LineBreak());
    _spaceWanted = false;
  }

  bool get _endsWithBreak => _inlines.isNotEmpty && _inlines.last is LineBreak;

  /// Joins runs with the same style and link, to keep the model small.
  void _append(TextRun run) {
    final last = _inlines.isEmpty ? null : _inlines.last;
    if (last is TextRun && last.style == run.style && last.link == run.link) {
      _inlines[_inlines.length - 1] = TextRun(
        last.text + run.text,
        style: run.style,
        link: run.link,
      );
    } else {
      _inlines.add(run);
    }
  }

  /// Ends the current paragraph.
  void flush(_Conversion conversion) {
    if (_hasContent) {
      // Line breaks at the edges of a paragraph only add empty lines.
      var start = 0;
      var end = _inlines.length;
      while (start < end && _inlines[start] is LineBreak) {
        start++;
      }
      while (end > start && _inlines[end - 1] is LineBreak) {
        end--;
      }
      addBlock(
        ParagraphBlock(List.unmodifiable(_inlines.sublist(start, end))),
        conversion,
      );
    }
    _inlines.clear();
    _spaceWanted = false;
  }

  void addBlock(Block block, _Conversion conversion) {
    conversion.countBlock();
    blocks.add(block);
  }

  /// The inline content of everything collected, for headings: paragraphs
  /// joined with line breaks.
  List<Inline> takeInlines(_Conversion conversion) {
    flush(conversion);
    final result = <Inline>[];
    for (final block in blocks) {
      if (block is ParagraphBlock) {
        if (result.isNotEmpty) result.add(const LineBreak());
        result.addAll(block.inlines);
      }
    }
    return result;
  }

  static final _whitespace = RegExp(r'[ \t\n\r\f]+');
}

final class _Conversion {
  _Conversion(this.limits, this.resolveContentId);

  final HtmlConverterLimits limits;
  final ContentIdResolver? resolveContentId;
  int remoteImages = 0;
  int trackers = 0;
  final trackerHosts = <String>{};
  bool truncated = false;
  int _blocks = 0;
  int _textLength = 0;

  /// Elements whose content is never shown.
  static const _dropped = {
    'head',
    'title',
    'meta',
    'link',
    'base',
    'style',
    'script',
    'noscript',
    'template',
    'iframe',
    'frame',
    'frameset',
    'object',
    'embed',
    'applet',
    'param',
    'svg',
    'math',
    'canvas',
    'video',
    'audio',
    'source',
    'track',
    'map',
    'area',
    'input',
    'select',
    'option',
    'optgroup',
    'textarea',
    'button',
    'datalist',
    'output',
    'progress',
    'meter',
    'dialog',
    'portal',
  };

  /// Elements that start and end a block (their content is walked).
  static const _blockContainers = {
    'html',
    'body',
    'div',
    'p',
    'section',
    'article',
    'header',
    'footer',
    'main',
    'nav',
    'aside',
    'center',
    'form',
    'fieldset',
    'legend',
    'figure',
    'figcaption',
    'address',
    'details',
    'summary',
    'dl',
    'dt',
    'dd',
    'table',
    'thead',
    'tbody',
    'tfoot',
    'tr',
    'td',
    'th',
    'caption',
    'li',
    'hgroup',
  };

  static const _headings = {
    'h1': 1,
    'h2': 2,
    'h3': 3,
    'h4': 4,
    'h5': 5,
    'h6': 6,
  };

  void countBlock() {
    if (++_blocks > limits.maxBlocks) throw const _LimitReached();
  }

  void countText(int length) {
    _textLength += length;
    if (_textLength > limits.maxTextLength) throw const _LimitReached();
  }

  void walkChildren(dom.Node parent, _Sink sink, _Context context) {
    for (final node in parent.nodes) {
      walk(node, sink, context);
    }
  }

  void walk(dom.Node node, _Sink sink, _Context context) {
    if (node is dom.Text) {
      countText(node.data.length);
      sink.addText(node.data, context);
      return;
    }
    if (node is! dom.Element) return; // comments, doctype
    if (context.depth >= limits.maxDepth) {
      truncated = true;
      return;
    }
    final name = node.localName?.toLowerCase() ?? '';
    if (_dropped.contains(name) || _isHidden(node)) return;

    final inner = context.deeper();
    switch (name) {
      case 'br':
        sink.lineBreak();
      case 'hr':
        sink
          ..flush(this)
          ..addBlock(const RuleBlock(), this);
      case 'img':
        _image(node, sink, context);
      case 'a':
        walkChildren(
          node,
          sink,
          context.deeper(
            link: SafeLinks.parse(node.attributes['href']),
            keepLink: false,
          ),
        );
      case 'b' || 'strong':
        walkChildren(
          node,
          sink,
          context.deeper(style: context.style.copyWith(bold: true)),
        );
      case 'i' || 'em' || 'cite' || 'var' || 'dfn':
        walkChildren(
          node,
          sink,
          context.deeper(style: context.style.copyWith(italic: true)),
        );
      case 'u' || 'ins':
        walkChildren(
          node,
          sink,
          context.deeper(style: context.style.copyWith(underline: true)),
        );
      case 's' || 'strike' || 'del':
        walkChildren(
          node,
          sink,
          context.deeper(style: context.style.copyWith(strike: true)),
        );
      case 'code' || 'kbd' || 'samp' || 'tt':
        walkChildren(
          node,
          sink,
          context.deeper(style: context.style.copyWith(code: true)),
        );
      case 'q':
        sink.addText('"', context);
        walkChildren(node, sink, inner);
        sink.addText('"', context);
      case 'pre' || 'xmp' || 'listing' || 'plaintext':
        sink.flush(this);
        final text = StringBuffer();
        _collectText(node, text, context.depth);
        countText(text.length);
        final value = text.toString().replaceAll(RegExp(r'^\n|\n$'), '');
        if (value.trim().isNotEmpty) {
          sink.addBlock(PreformattedBlock(value), this);
        }
      case 'blockquote':
        sink.flush(this);
        final quote = _Sink();
        walkChildren(node, quote, inner);
        quote.flush(this);
        if (quote.blocks.isNotEmpty) {
          sink.addBlock(QuoteBlock(List.unmodifiable(quote.blocks)), this);
        }
      case 'ul' || 'ol' || 'menu' || 'dir':
        _list(node, sink, inner, ordered: name == 'ol');
      case 'table' when _isDataTable(node):
        _table(node, sink, inner);
      default:
        if (_headings[name] case final level?) {
          sink.flush(this);
          final heading = _Sink();
          walkChildren(node, heading, inner);
          final inlines = heading.takeInlines(this);
          if (inlines.isNotEmpty) {
            sink.addBlock(
              HeadingBlock(level, List.unmodifiable(inlines)),
              this,
            );
          }
        } else if (_blockContainers.contains(name)) {
          sink.flush(this);
          walkChildren(node, sink, inner);
          sink.flush(this);
        } else {
          walkChildren(node, sink, inner); // span, font, unknown: inline
        }
    }
  }

  /// `hidden`, `display:none` or `visibility:hidden` in the style attribute.
  static bool _isHidden(dom.Element element) {
    if (element.attributes.containsKey('hidden')) return true;
    final style = element.attributes['style'];
    if (style == null) return false;
    final compact = style.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return compact.contains('display:none') ||
        compact.contains('visibility:hidden');
  }

  void _collectText(dom.Node node, StringBuffer out, int depth) {
    if (depth >= limits.maxDepth) {
      truncated = true;
      return;
    }
    for (final child in node.nodes) {
      if (child is dom.Text) {
        out.write(child.data);
      } else if (child is dom.Element) {
        final name = child.localName?.toLowerCase() ?? '';
        if (name == 'br') {
          out.write('\n');
        } else if (!_dropped.contains(name) && !_isHidden(child)) {
          _collectText(child, out, depth + 1);
        }
      }
    }
  }

  void _list(
    dom.Element list,
    _Sink sink,
    _Context context, {
    required bool ordered,
  }) {
    sink.flush(this);
    final items = <List<Block>>[];
    final loose = _Sink(); // text directly inside the list, outside items
    for (final node in list.nodes) {
      if (node is dom.Element &&
          !_dropped.contains(node.localName?.toLowerCase()) &&
          !_isHidden(node)) {
        loose.flush(this);
        if (loose.blocks.isNotEmpty) {
          items.add(List.unmodifiable(loose.blocks));
          loose.blocks.clear();
        }
        final item = _Sink();
        if (node.localName?.toLowerCase() == 'li') {
          walkChildren(node, item, context.deeper());
        } else {
          walk(node, item, context);
        }
        item.flush(this);
        if (item.blocks.isNotEmpty) items.add(List.unmodifiable(item.blocks));
      } else {
        walk(node, loose, context);
      }
    }
    loose.flush(this);
    if (loose.blocks.isNotEmpty) items.add(List.unmodifiable(loose.blocks));
    if (items.isNotEmpty) {
      sink.addBlock(
        ListBlock(ordered: ordered, items: List.unmodifiable(items)),
        this,
      );
    }
  }

  /// A table with header cells and a sensible size is shown as a table;
  /// layout tables (most email HTML) are flattened.
  bool _isDataTable(dom.Element table) {
    final rows = _rows(table);
    if (rows.isEmpty) return false;
    var cells = 0;
    var headers = false;
    for (final row in rows) {
      for (final cell in _cells(row)) {
        cells++;
        if (cell.localName?.toLowerCase() == 'th') headers = true;
        // Nested tables mean layout.
        if (_containsTable(cell, 0)) return false;
      }
    }
    return headers && cells <= limits.maxTableCells;
  }

  /// Whether [element] has a table inside, looking at most [limits]
  /// levels deep (the DOM library's own search is unbounded recursion).
  bool _containsTable(dom.Element element, int depth) {
    if (depth >= limits.maxDepth) return true; // too deep to be a data table
    for (final child in element.children) {
      if (child.localName == 'table' || _containsTable(child, depth + 1)) {
        return true;
      }
    }
    return false;
  }

  static List<dom.Element> _rows(dom.Element table) => [
    for (final child in table.children)
      if (child.localName == 'tr')
        child
      else if (const {'thead', 'tbody', 'tfoot'}.contains(child.localName))
        ...child.children.where((r) => r.localName == 'tr'),
  ];

  static Iterable<dom.Element> _cells(dom.Element row) =>
      row.children.where((c) => c.localName == 'td' || c.localName == 'th');

  void _table(dom.Element table, _Sink sink, _Context context) {
    sink.flush(this);
    final rows = <List<TableCell>>[];
    for (final row in _rows(table)) {
      final cells = <TableCell>[];
      for (final cell in _cells(row)) {
        final content = _Sink();
        walkChildren(cell, content, context.deeper());
        content.flush(this);
        cells.add(
          TableCell(
            List.unmodifiable(content.blocks),
            header: cell.localName == 'th',
          ),
        );
      }
      if (cells.isNotEmpty) rows.add(List.unmodifiable(cells));
    }
    if (rows.isNotEmpty) {
      sink.addBlock(TableBlock(List.unmodifiable(rows)), this);
    }
  }

  void _image(dom.Element img, _Sink sink, _Context context) {
    final src = (img.attributes['src'] ?? '').trim();
    final alt = (img.attributes['alt'] ?? '').trim();
    final width = _size(img.attributes['width']);
    final height = _size(img.attributes['height']);
    final remote = _remoteUrl(src);
    if (remote != null) {
      if (TrackingPixels.isTracker(
        remote,
        width: width,
        height: height,
        style: img.attributes['style'],
      )) {
        // Never shown, never loaded, not even its description.
        trackers++;
        if (trackerHosts.length < 5) trackerHosts.add(remote.host);
        return;
      }
      remoteImages++;
      if (remoteImages > limits.maxRemoteImages) return;
      sink.addInline(
        RemoteImageInline(
          remote,
          alt: alt,
          width: width,
          height: height,
          link: context.link,
        ),
      );
      return;
    }
    final embedded = _embeddedImage(src);
    if (embedded == null) {
      // Broken or unusable: its description stands in for it.
      final tiny =
          (width != null && width <= 2) || (height != null && height <= 2);
      if (alt.isNotEmpty && !tiny) {
        sink.addText(
          '[$alt]',
          context.deeper(style: context.style.copyWith(italic: true)),
        );
      }
      return;
    }
    sink.addInline(
      ImageInline(
        embedded.bytes,
        mimeType: embedded.mimeType,
        alt: alt,
        width: width,
        height: height,
        link: context.link,
      ),
    );
  }

  static const _imageTypes = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  };

  ContentIdImage? _embeddedImage(String src) {
    final lower = src.toLowerCase();
    ContentIdImage? image;
    if (lower.startsWith('cid:')) {
      final String id;
      try {
        id = Uri.decodeComponent(src.substring(4).trim());
      } on ArgumentError {
        return null; // broken percent-encoding
      }
      image = resolveContentId?.call(id.replaceAll(RegExp(r'^<|>$'), ''));
    } else if (lower.startsWith('data:')) {
      image = _dataUri(src);
    }
    if (image == null) return null;
    final type = image.mimeType.toLowerCase() == 'image/jpg'
        ? 'image/jpeg'
        : image.mimeType.toLowerCase();
    if (!_imageTypes.contains(type)) return null; // never SVG
    if (image.bytes.length > limits.maxImageBytes) return null;
    // The bytes decide, not the label: a readable header of an allowed
    // type and a size safe to decode.
    final info = ImageHeader.read(image.bytes);
    if (info == null) return null;
    return (bytes: image.bytes, mimeType: info.mimeType);
  }

  /// A remote image's address as https, or null for anything else
  /// (`cid:`, `data:`, relative or unusable addresses).
  static Uri? _remoteUrl(String src) {
    if (src.isEmpty || src.length > 4096) return null;
    var text = src;
    if (text.startsWith('//')) text = 'https:$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    return switch (uri.scheme.toLowerCase()) {
      'https' => uri,
      'http' => uri.replace(scheme: 'https'),
      _ => null,
    };
  }

  /// `data:image/png;base64,...` only.
  ContentIdImage? _dataUri(String src) {
    final comma = src.indexOf(',');
    if (comma < 0) return null;
    final meta = src.substring(5, comma).toLowerCase().split(';');
    if (!meta.contains('base64')) return null;
    final encoded = src.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
    if (encoded.length > limits.maxImageBytes * 4 ~/ 3 + 4) return null;
    try {
      return (bytes: base64.decode(encoded), mimeType: meta.first.trim());
    } on FormatException {
      return null;
    }
  }

  static double? _size(String? value) {
    final match = RegExp(r'^\s*(\d{1,5})').firstMatch(value ?? '');
    return match == null ? null : double.parse(match.group(1)!);
  }
}
