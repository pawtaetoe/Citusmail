// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

final fixtureDir = Directory('../../test-data/mail');

MessageView fixture(String name) =>
    MessageView.parse(File('${fixtureDir.path}/$name').readAsBytesSync());

RichDocument convert(String html, {ContentIdResolver? cid}) =>
    const HtmlConverter().convert(html, resolveContentId: cid);

/// Every inline in the document, depth first.
Iterable<Inline> inlines(List<Block> blocks) sync* {
  for (final block in blocks) {
    switch (block) {
      case ParagraphBlock(inlines: final i) || HeadingBlock(inlines: final i):
        yield* i;
      case QuoteBlock(:final children):
        yield* inlines(children);
      case ListBlock(:final items):
        for (final item in items) {
          yield* inlines(item);
        }
      case TableBlock(:final rows):
        for (final row in rows) {
          for (final cell in row) {
            yield* inlines(cell.blocks);
          }
        }
      case PreformattedBlock() || RuleBlock():
        break;
    }
  }
}

Iterable<Uri> links(RichDocument d) => inlines(d.blocks).expand(
  (i) => switch (i) {
    TextRun(:final link?) => [link],
    ImageInline(:final link?) => [link],
    _ => const <Uri>[],
  },
);

/// The safety property: only http(s)/mailto links (which are only opened
/// when tapped), and only images whose bytes are inside the message.
void expectSafe(RichDocument d) {
  for (final link in links(d)) {
    expect(SafeLinks.schemes, contains(link.scheme), reason: '$link');
  }
}

/// A real 1 x 1 PNG.
final _png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  group('hostile HTML', () {
    late MessageView view;
    setUp(() => view = fixture('security/hostile-html.eml'));

    test('keeps the visible text', () {
      final text = view.body.plainText;
      expect(text, contains('Visible text that must still render.'));
      expect(text, contains('javascript link'));
      expect(text, contains('inline style'));
      expect(text, contains('table'));
    });

    test('nothing that runs code or loads anything survives', () {
      final text = view.body.plainText;
      for (final banned in [
        'fetch(',
        '@import',
        'font-face',
        'evil.example/style',
      ]) {
        expect(text, isNot(contains(banned)));
      }
      expect(inlines(view.body.blocks).whereType<ImageInline>(), isEmpty);
      expectSafe(view.body);
      // The only link left is the normal one, which opens only on a tap.
      expect(links(view.body).map((u) => u.toString()), [
        'https://evil.example/normal-link',
      ]);
      // The pixel is a tracker; "x" and srcset-only images are not
      // loadable at all.
      expect(view.body.trackers, 1);
      expect(view.body.remoteImages, 0);
      expect(inlines(view.body.blocks).whereType<RemoteImageInline>(), isEmpty);
    });

    test('the form and its password field are gone', () {
      expect(view.body.plainText, isNot(contains('Log in')));
    });
  });

  test('every fixture parses and gives a body or attachments', () {
    final files = fixtureDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.eml'));
    for (final file in files) {
      final view = MessageView.parse(file.readAsBytesSync());
      expectSafe(view.body);
      expect(
        view.body.blocks.isNotEmpty || view.attachments.isNotEmpty,
        isTrue,
        reason: file.path,
      );
    }
  });

  group('HTML structure', () {
    test('paragraphs, headings, emphasis and whitespace', () {
      final d = convert(
        '<h2>Title</h2><p>Hello   <b>bold</b>\n<i>it</i>!</p><p>Line<br>two</p>',
      );
      expect(d.blocks, hasLength(3));
      final heading = d.blocks[0] as HeadingBlock;
      expect(heading.level, 2);
      final para = d.blocks[1] as ParagraphBlock;
      expect(
        para.inlines.whereType<TextRun>().map((r) => r.text).join(),
        'Hello bold it!',
      );
      expect((para.inlines[1] as TextRun).style.bold, isTrue);
      expect(d.blocks[2], isA<ParagraphBlock>());
      expect((d.blocks[2] as ParagraphBlock).inlines[1], isA<LineBreak>());
    });

    test('lists, quotes, preformatted text and rules', () {
      final d = convert(
        '<ul><li>one</li><li>two <b>b</b></li></ul><blockquote><p>quoted</p></blockquote>'
        '<pre>  keep   spaces\nand lines</pre><hr>',
      );
      final list = d.blocks[0] as ListBlock;
      expect(list.ordered, isFalse);
      expect(list.items, hasLength(2));
      expect(d.blocks[1], isA<QuoteBlock>());
      expect(
        (d.blocks[2] as PreformattedBlock).text,
        '  keep   spaces\nand lines',
      );
      expect(d.blocks[3], isA<RuleBlock>());
    });

    test('data tables stay tables; layout tables are flattened', () {
      final data = convert(
        '<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>',
      );
      expect((data.blocks.single as TableBlock).rows, hasLength(2));
      final layout = convert(
        '<table><tr><td>left</td><td>right</td></tr></table>',
      );
      expect(layout.blocks.map((b) => b.runtimeType), [
        ParagraphBlock,
        ParagraphBlock,
      ]);
    });

    test('only http, https and mailto links are links', () {
      final d = convert(
        '<a href="https://ok.example/x">a</a> <a href="mailto:me@x.example">b</a> '
        '<a href="javascript:alert(1)">c</a> <a href="file:///etc/passwd">d</a> '
        '<a href="data:text/html,hi">e</a> <a href=" JaVaScRiPt:alert(1)">f</a> '
        '<a href="/relative">g</a> <a href="myapp://do">h</a>',
      );
      expect(links(d).map((u) => u.toString()), [
        'https://ok.example/x',
        'mailto:me@x.example',
      ]);
      expect(d.plainText, contains('a b c d e f g h'));
    });

    test('hidden content is left out', () {
      final d = convert(
        '<div style="display: none">preheader</div><span hidden>secret</span>'
        '<p style="VISIBILITY:hidden">x</p><p>shown</p>',
      );
      expect(d.plainText.trim(), 'shown');
    });

    test('remote images wait as addresses; tracking pixels leave nothing', () {
      final d = convert(
        '<p><img src="https://t.example/p.gif" width="1" height="1" alt="pixel">'
        '<img src="http://cdn.example/logo.png" alt="Logo">'
        '<img src="//cdn.example/x.png"><img src="relative.png" alt="rel">'
        '<img src="https://x.example/track/open?id=1" alt="o">'
        '<img src="https://r.us-east-1.awstrack.me/I0/abc">'
        '<img src="https://cdn.example/s.png" style="width: 1px; height:1px">'
        '<img src="javascript:alert(1)" alt="js"></p>',
      );
      final remote = inlines(d.blocks).whereType<RemoteImageInline>().toList();
      expect(remote.map((i) => i.url.toString()), [
        'https://cdn.example/logo.png',
        'https://cdn.example/x.png',
      ]);
      expect(remote.first.alt, 'Logo');
      expect(d.remoteImages, 2);
      expect(d.trackers, 4);
      expect(d.trackerHosts, {
        't.example',
        'x.example',
        'r.us-east-1.awstrack.me',
        'cdn.example',
      });
      expect(d.plainText, contains('[rel]'));
      expect(d.plainText, contains('[js]'));
      expect(d.plainText, isNot(contains('pixel')));
      expect(inlines(d.blocks).whereType<ImageInline>(), isEmpty);
    });

    test('remote images beyond the limit are counted, not kept', () {
      final d = const HtmlConverter(
        limits: HtmlConverterLimits(maxRemoteImages: 2),
      ).convert('<img src="https://a.example/1.png">' * 5);
      expect(d.remoteImages, 5);
      expect(inlines(d.blocks).whereType<RemoteImageInline>(), hasLength(2));
    });

    test('embedded images: cid and data URIs; never SVG or oversized', () {
      final png = _png;
      final d = convert(
        '<img src="cid:logo@x" alt="cid">'
        '<img src="CID:%3Clogo@x%3E">'
        '<img src="cid:missing@x" alt="gone">'
        '<img src="cid:%E0%A4%A">'
        '<img src="data:image/png;base64,${base64.encode(png)}">'
        '<img src="data:image/svg+xml;base64,${base64.encode(utf8.encode('<svg/>'))}">',
        cid: (id) =>
            id == 'logo@x' ? (bytes: png, mimeType: 'image/png') : null,
      );
      final images = inlines(d.blocks).whereType<ImageInline>().toList();
      expect(images, hasLength(3));
      expect(images.first.alt, 'cid');
      expect(images.every((i) => i.mimeType == 'image/png'), isTrue);
      expect(d.remoteImages + d.trackers, 0);

      // The bytes decide: a "PNG" that isn't one is left out.
      final fake = convert(
        '<img src="data:image/png;base64,${base64.encode([0x89, 0x50, 0x4E, 0x47, 1, 2])}" alt="fake">',
      );
      expect(inlines(fake.blocks).whereType<ImageInline>(), isEmpty);
      expect(fake.plainText.trim(), '[fake]');

      final big = const HtmlConverter(
        limits: HtmlConverterLimits(maxImageBytes: 4),
      ).convert('<img src="data:image/png;base64,${base64.encode(png)}">');
      expect(inlines(big.blocks).whereType<ImageInline>(), isEmpty);
    });

    test('links around embedded images are kept', () {
      final png = _png;
      final d = convert(
        '<a href="https://shop.example"><img src="cid:a"></a>',
        cid: (_) => (bytes: png, mimeType: 'image/png'),
      );
      expect(
        inlines(d.blocks).whereType<ImageInline>().single.link,
        Uri.parse('https://shop.example'),
      );
    });

    test('deep nesting is cut off instead of crashing', () {
      final deep = '${'<div>' * 20000}deep text${'</div>' * 20000}<p>after</p>';
      final d = convert(deep);
      expect(d.truncated, isTrue);
      final deepTable =
          '<table><tr><th>h</th><td>${'<span>' * 5000}x${'</span>' * 5000}</td></tr></table>';
      expect(() => convert(deepTable), returnsNormally);
    });

    test('size limits stop runaway documents', () {
      final many = '<p>x</p>' * 50;
      final d = const HtmlConverter(limits: HtmlConverterLimits(maxBlocks: 10))
          .convert(many);
      expect(d.truncated, isTrue);
      expect(d.blocks.length, lessThanOrEqualTo(10));
      final long = const HtmlConverter(
        limits: HtmlConverterLimits(maxSourceLength: 20),
      ).convert('<p>${'a' * 100}</p>');
      expect(long.truncated, isTrue);
    });
  });

  group('plain text', () {
    const converter = PlainTextConverter();

    test('paragraphs, quotes and nested quotes', () {
      final d = converter.convert(
        'Hi Bob,\nthanks.\n\n> You wrote\n> > Deeper\n> back\n\nBye',
      );
      expect(d.blocks.map((b) => b.runtimeType), [
        ParagraphBlock,
        QuoteBlock,
        ParagraphBlock,
      ]);
      final quote = d.blocks[1] as QuoteBlock;
      expect(quote.children.map((b) => b.runtimeType), [
        ParagraphBlock,
        QuoteBlock,
        ParagraphBlock,
      ]);
    });

    test('web and mail addresses become links, without trailing punctuation', () {
      final d = converter.convert(
        'See https://x.example/a?b=1. Or www.y.example, or mail bob@z.example!',
      );
      expect(links(d).map((u) => u.toString()), [
        'https://x.example/a?b=1',
        'https://www.y.example',
        'mailto:bob@z.example',
      ]);
      expect(
        d.plainText.trim(),
        'See https://x.example/a?b=1. Or www.y.example, or mail bob@z.example!',
      );
    });

    test('format=flowed joins soft line breaks', () {
      final d = converter.convert(
        'This is a long \nline that was \nwrapped.\nNew line.\n>quoted \n>more',
        flowed: true,
      );
      expect(
        d.plainText,
        'This is a long line that was wrapped.\nNew line.\nquoted more\n',
      );
    });
  });

  group('attachments', () {
    test('names are decoded and made safe', () {
      expect(
        fixture('people/rfc2231-filename.eml').attachments.single.fileName,
        '“Quarterly report” €.txt',
      );
      final risky = fixture('security/risky-attachments.eml').attachments;
      expect(risky.map((a) => a.fileName), [
        'invoice.html',
        'invoice.pdf.exe',
        'terms.docm',
      ]);
    });

    test('inline images used by the HTML are not listed as attachments', () {
      final view = fixture('people/attachment-inline-image.eml');
      expect(
        view.attachments.map((a) => a.fileName),
        isNot(contains('logo.png')),
      );
      expect(inlines(view.body.blocks).whereType<ImageInline>(), hasLength(1));
      expect(view.attachments.first.bytes(), isNotEmpty);
    });
  });

  group('safe file names', () {
    test('cases', () {
      final cases = {
        '../../etc/passwd': 'passwd',
        r'..\..\Windows\evil.bat': 'evil.bat',
        'invoice\u202Efdp.exe': 'invoicefdp.exe',
        'a<b>c:d"e|f?g*h.txt': 'a_b_c_d_e_f_g_h.txt',
        '.bashrc': 'bashrc',
        'name. . ': 'name',
        'CON.txt': '_CON.txt',
        'lpt1': '_lpt1',
        'COM¹.log': '_COM¹.log',
        'console.txt': 'console.txt',
        'tab\tand\nnewline.txt': 'tab and newline.txt',
        '': 'attachment',
        '...': 'attachment',
        '​​': 'attachment',
      };
      for (final MapEntry(key: input, value: expected) in cases.entries) {
        expect(SafeFileName.from(input), expected, reason: input);
      }
      expect(SafeFileName.from(null), 'attachment');
    });

    test('long names are cut to 200 UTF-8 bytes, keeping the extension', () {
      final name = SafeFileName.from('${'é' * 300}.pdf');
      expect(utf8.encode(name).length, lessThanOrEqualTo(200));
      expect(name, endsWith('.pdf'));
    });
  });
}
