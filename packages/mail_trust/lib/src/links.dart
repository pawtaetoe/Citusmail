// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_view/mail_view.dart';

import 'generated/public_suffixes.g.dart';

/// A link as the reader shows it: where it goes and the text on it.
final class ShownLink {
  const ShownLink(this.link, this.text);

  final Uri link;

  /// The visible text, joined across style changes (`<b>pay</b>pal.com`).
  final String text;
}

/// Finds the links in a document.
abstract final class DocumentLinks {
  /// Most links examined per message (hostile mail can have thousands).
  static const maxLinks = 500;

  static List<ShownLink> collect(RichDocument document) {
    final out = <ShownLink>[];
    Uri? current;
    final text = StringBuffer();

    void flush() {
      if (current != null && out.length < maxLinks) {
        out.add(ShownLink(current!, text.toString().trim()));
      }
      current = null;
      text.clear();
    }

    void inlines(List<Inline> list) {
      for (final inline in list) {
        final link = switch (inline) {
          TextRun(:final link) => link,
          ImageInline(:final link) => link,
          RemoteImageInline(:final link) => link,
          LineBreak() => null,
        };
        if (link != current) flush();
        current = link;
        if (inline is TextRun && link != null) text.write(inline.text);
      }
      flush();
    }

    void blocks(List<Block> list) {
      for (final block in list) {
        if (out.length >= maxLinks) return;
        switch (block) {
          case ParagraphBlock(inlines: final i) ||
              HeadingBlock(inlines: final i):
            inlines(i);
          case QuoteBlock(:final children):
            blocks(children);
          case ListBlock(:final items):
            items.forEach(blocks);
          case TableBlock(:final rows):
            for (final row in rows) {
              for (final cell in row) {
                blocks(cell.blocks);
              }
            }
          case PreformattedBlock() || RuleBlock():
            break;
        }
      }
    }

    blocks(document.blocks);
    return out;
  }

  /// The host that link text shows, if the whole text is a web address
  /// (`www.paypal.com`, `https://paypal.com/signin`); otherwise null.
  static String? shownHost(String text) {
    var t = text.trim().toLowerCase();
    if (t.isEmpty || t.length > 2048 || t.contains(RegExp(r'\s'))) return null;
    final scheme = RegExp(r'^https?://').firstMatch(t);
    if (scheme != null) t = t.substring(scheme.end);
    final end = t.indexOf(RegExp(r'[/?#:]'));
    final host = end < 0 ? t : t.substring(0, end);
    if (host.contains('@')) return null; // an email address
    final labels = host.split('.');
    if (labels.length < 2 || labels.any((l) => l.isEmpty)) return null;
    if (!RegExp('^[a-z0-9\\u00a1-\\uffff-]+\$').hasMatch(labels.join())) {
      return null;
    }
    // Must end in a real domain ending, so "invoice.pdf" or "v1.2" are not
    // taken for addresses. Some endings are also file extensions
    // ("photos.zip"): those count only with "https://" or "www.".
    final tld = labels.last;
    if (!publicSuffixRules.contains(tld) && !tld.startsWith('xn--')) {
      return null;
    }
    if (scheme == null &&
        !host.startsWith('www.') &&
        RegExp(r'^(zip|mov|py|sh|rs|pl|md|app|dev)$').hasMatch(tld)) {
      return null;
    }
    return host;
  }
}
