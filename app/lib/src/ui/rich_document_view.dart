// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mail_view/mail_view.dart' hide TableCell;
import 'package:mail_view/mail_view.dart' as view show TableCell;

/// Fetches a remote image the user chose to load; null if it can't be
/// shown.
typedef RemoteImageSource = Future<Uint8List?> Function(Uri url);

/// Draws one top-level block of a [RichDocument]. The reader builds
/// blocks lazily as they scroll into view, so a very long message costs no
/// more than what is on screen. Drawing never touches the network by
/// itself: remote images appear only through [images], which the reader
/// passes only after the user asked to load them.
final class BlockView extends StatefulWidget {
  const BlockView({
    super.key,
    required this.block,
    required this.onLink,
    this.images,
  });

  final Block block;

  /// A link was tapped (the caller confirms before opening anything).
  final void Function(Uri link) onLink;

  /// Loads remote images; null while they stay hidden.
  final RemoteImageSource? images;

  @override
  State<BlockView> createState() => _BlockViewState();
}

final class _BlockViewState extends State<BlockView> {
  /// Tap handlers for links, recreated on every build and disposed.
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    return _block(context, widget.block);
  }

  List<Widget> _blocks(BuildContext context, List<Block> blocks) => [
    for (final block in blocks) _block(context, block),
  ];

  Widget _block(BuildContext context, Block block) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge!.copyWith(height: 1.45);
    return switch (block) {
      ParagraphBlock(:final inlines) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _rich(context, inlines, base),
      ),
      HeadingBlock(:final level, :final inlines) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: _rich(
          context,
          inlines,
          base.copyWith(
            fontSize: switch (level) {
              1 => 24.0,
              2 => 21.0,
              3 => 18.0,
              _ => 16.0,
            },
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      QuoteBlock(:final children) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
          ),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _blocks(context, children),
          ),
        ),
      ),
      ListBlock(:final ordered, :final items) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      ordered ? '${i + 1}.' : '•',
                      style: base,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _blocks(context, items[i]),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      PreformattedBlock(:final text) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text,
            style: base.copyWith(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
      ),
      RuleBlock() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(),
      ),
      TableBlock(:final rows) => _table(context, rows),
    };
  }

  Widget _table(BuildContext context, List<List<view.TableCell>> rows) {
    final columns = rows.fold(
      0,
      (max, row) => row.length > max ? row.length : max,
    );
    final border = BorderSide(
      color: Theme.of(context).colorScheme.outlineVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder(
            horizontalInside: border,
            verticalInside: border,
            top: border,
            bottom: border,
            left: border,
            right: border,
          ),
          children: [
            for (final row in rows)
              TableRow(
                children: [
                  for (var c = 0; c < columns; c++)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: c < row.length
                          ? DefaultTextStyle.merge(
                              style: TextStyle(
                                fontWeight: row[c].header
                                    ? FontWeight.w600
                                    : null,
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: _blocks(context, row[c].blocks),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _rich(BuildContext context, List<Inline> inlines, TextStyle base) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    for (final inline in inlines) {
      switch (inline) {
        case TextRun(:final text, :final style, :final link):
          TapGestureRecognizer? recognizer;
          if (link != null) {
            recognizer = TapGestureRecognizer()
              ..onTap = () => widget.onLink(link);
            _recognizers.add(recognizer);
          }
          spans.add(
            TextSpan(
              text: text,
              recognizer: recognizer,
              mouseCursor: link == null ? null : SystemMouseCursors.click,
              style: TextStyle(
                fontWeight: style.bold ? FontWeight.w700 : null,
                fontStyle: style.italic ? FontStyle.italic : null,
                fontFamily: style.code ? 'monospace' : null,
                color: link == null ? null : theme.colorScheme.primary,
                decoration: TextDecoration.combine([
                  if (style.underline || link != null) TextDecoration.underline,
                  if (style.strike) TextDecoration.lineThrough,
                ]),
              ),
            ),
          );
        case LineBreak():
          spans.add(const TextSpan(text: '\n'));
        case ImageInline():
          spans.add(
            WidgetSpan(
              child: _image(
                inline.bytes,
                alt: inline.alt,
                width: inline.width,
                height: inline.height,
                link: inline.link,
              ),
            ),
          );
        case RemoteImageInline():
          final source = widget.images;
          if (source != null) {
            spans.add(
              WidgetSpan(
                child: _RemoteImage(
                  inline,
                  source: source,
                  build: (bytes) => _image(
                    bytes,
                    alt: inline.alt,
                    width: inline.width,
                    height: inline.height,
                    link: inline.link,
                  ),
                ),
              ),
            );
          } else if (inline.alt.isNotEmpty) {
            // Hidden: its description stands in for it.
            spans.add(
              TextSpan(
                text: '[${inline.alt}]',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            );
          }
      }
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }

  /// Widest an image is drawn; it is also decoded no larger than this
  /// (times the screen density), so a large image costs little memory.
  static const _maxWidth = 640.0;

  Widget _image(
    Uint8List bytes, {
    required String alt,
    double? width,
    double? height,
    Uri? link,
  }) {
    final density = MediaQuery.devicePixelRatioOf(context);
    final picture = Image.memory(
      bytes,
      width: width,
      height: height,
      // Never upscaled; only shrinks large images while decoding.
      cacheWidth: (_maxWidth * density).round(),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: alt.isEmpty ? null : alt,
      errorBuilder: (_, _, _) => Text(alt.isEmpty ? '[image]' : '[$alt]'),
    );
    final constrained = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth, maxHeight: 2000),
      child: picture,
    );
    if (link == null) return constrained;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onLink(link),
        child: constrained,
      ),
    );
  }
}

/// A remote image being fetched: a placeholder of its size while it
/// loads, the image when it arrives, its description if it can't be shown.
final class _RemoteImage extends StatefulWidget {
  const _RemoteImage(this.image, {required this.source, required this.build});

  final RemoteImageInline image;
  final RemoteImageSource source;
  final Widget Function(Uint8List bytes) build;

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

final class _RemoteImageState extends State<_RemoteImage> {
  late final Future<Uint8List?> _bytes = widget.source(widget.image.url);

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes != null) return widget.build(bytes);
      final alt = widget.image.alt;
      if (snapshot.connectionState == ConnectionState.done) {
        return alt.isEmpty
            ? const SizedBox.shrink()
            : Text(
                '[$alt]',
                style: const TextStyle(fontStyle: FontStyle.italic),
              );
      }
      return SizedBox(
        width: (widget.image.width ?? 48).clamp(16, 640),
        height: (widget.image.height ?? 48).clamp(16, 400),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      );
    },
  );
}
