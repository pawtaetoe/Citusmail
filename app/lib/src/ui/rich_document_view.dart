// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mail_view/mail_view.dart' hide TableCell;
import 'package:mail_view/mail_view.dart' as view show TableCell;

/// Draws a [RichDocument]. It only has text, structure and image bytes
/// that came inside the message, so drawing it never touches the network.
final class RichDocumentView extends StatefulWidget {
  const RichDocumentView({
    super.key,
    required this.document,
    required this.onLink,
  });

  final RichDocument document;

  /// A link was tapped (the caller confirms before opening anything).
  final void Function(Uri link) onLink;

  @override
  State<RichDocumentView> createState() => _RichDocumentViewState();
}

final class _RichDocumentViewState extends State<RichDocumentView> {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _blocks(context, widget.document.blocks),
    );
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
          spans.add(WidgetSpan(child: _image(inline)));
      }
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }

  Widget _image(ImageInline image) {
    final picture = Image.memory(
      image.bytes,
      width: image.width,
      height: image.height,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: image.alt.isEmpty ? null : image.alt,
      errorBuilder: (_, _, _) =>
          Text(image.alt.isEmpty ? '[image]' : '[${image.alt}]'),
    );
    final constrained = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 2000),
      child: picture,
    );
    final link = image.link;
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
