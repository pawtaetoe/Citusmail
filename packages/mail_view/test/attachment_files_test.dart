// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_view/mail_view.dart';
import 'package:test/test.dart';

ImapBodyPart part(
  String section,
  String type, {
  String? name,
  String? disposition,
  String? cid,
  int size = 0,
  String encoding = 'BASE64',
  List<ImapBodyPart> children = const [],
}) {
  final [main, sub] = type.split('/');
  return ImapBodyPart(
    section: section,
    contentType: ContentType(main, sub, MimeParameters({'name': ?name})),
    encoding: encoding,
    size: size,
    contentId: cid,
    disposition: disposition == null
        ? null
        : ContentDisposition(disposition, MimeParameters({'filename': ?name})),
    children: children,
  );
}

/// A raw message from lines.
List<int> raw(List<String> lines) => utf8.encode(lines.join('\r\n'));

void main() {
  group('FileKind', () {
    test('by extension first, then by type', () {
      expect(
        FileKind.of('Invoice 2026-10.pdf', 'application/octet-stream'),
        FileKind.pdf,
      );
      expect(
        FileKind.of('IMG_2041.HEIC', 'application/octet-stream'),
        FileKind.image,
      );
      expect(FileKind.of('scan', 'image/jpeg'), FileKind.image);
      expect(
        FileKind.of('Contract draft v3.docx', 'application/msword'),
        FileKind.document,
      );
      expect(FileKind.of('Q3 slides.pptx', ''), FileKind.document);
      expect(FileKind.of('budget.xlsx', ''), FileKind.spreadsheet);
      expect(FileKind.of('export.csv', 'text/plain'), FileKind.spreadsheet);
      expect(
        FileKind.of(
          'sheet',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        FileKind.spreadsheet,
      );
      expect(FileKind.of('photos.zip', ''), FileKind.archive);
      expect(FileKind.of('invite.ics', 'text/calendar'), FileKind.calendar);
      expect(FileKind.of('meeting', 'text/calendar'), FileKind.calendar);
      expect(
        FileKind.of('setup.exe', 'application/x-msdownload'),
        FileKind.other,
      );
      expect(FileKind.of('.pdf', 'application/octet-stream'), FileKind.other);
    });

    test('filters group kinds; Other takes archives and invitations', () {
      expect(FileFilter.all.includes(FileKind.archive), isTrue);
      expect(FileFilter.pdfs.includes(FileKind.pdf), isTrue);
      expect(FileFilter.pdfs.includes(FileKind.document), isFalse);
      expect(FileFilter.images.includes(FileKind.image), isTrue);
      expect(FileFilter.documents.includes(FileKind.document), isTrue);
      expect(FileFilter.spreadsheets.includes(FileKind.spreadsheet), isTrue);
      expect(FileFilter.other.includes(FileKind.archive), isTrue);
      expect(FileFilter.other.includes(FileKind.calendar), isTrue);
      expect(FileFilter.other.includes(FileKind.other), isTrue);
      expect(FileFilter.other.includes(FileKind.image), isFalse);
    });
  });

  group('from the BODYSTRUCTURE', () {
    // An Outlook-style message: text and HTML with a signature logo, a
    // tiny spacer, a pasted screenshot, and two real attachments.
    final root = part(
      '',
      'multipart/mixed',
      children: [
        part(
          '1',
          'multipart/related',
          children: [
            part('1.1', 'text/html', encoding: 'QUOTED-PRINTABLE', size: 9000),
            part(
              '1.2',
              'image/png',
              name: 'image001.png',
              cid: 'image001',
              size: 12000,
            ),
            part('1.3', 'image/gif', name: 'spacer.gif', size: 60),
            part(
              '1.4',
              'image/png',
              name: 'screenshot.png',
              disposition: 'inline',
              size: 80000,
            ),
          ],
        ),
        part(
          '2',
          'application/pdf',
          name: 'Lease agreement.pdf',
          disposition: 'attachment',
          size: 400000,
        ),
        part(
          '3',
          'image/jpeg',
          name: 'IMG_0412.jpg',
          disposition: 'attachment',
          size: 2400000,
        ),
      ],
    );

    test('lists what the reader lists, with decoded sizes', () {
      final files = FilePart.listFromImap(root);
      expect(files.map((f) => f.name), [
        'image001.png',
        'spacer.gif',
        'Lease agreement.pdf',
        'IMG_0412.jpg',
      ]);
      expect(files[2].size, 300000); // base64 shrinks by a quarter
      expect(files[2].kind, FileKind.pdf);
    });

    test('logos, signature pictures and spacers are not files', () {
      final files = FilePart.listFromImap(root);
      expect(files.where((f) => !f.isLayoutImage).map((f) => f.name), [
        'Lease agreement.pdf',
        'IMG_0412.jpg',
      ]);
    });

    test('a big photo sent inline is still a file', () {
      const photo = FilePart(
        name: 'IMG_0099.jpg',
        mimeType: 'image/jpeg',
        size: 1800000,
        inline: true,
        hasContentId: true,
      );
      expect(photo.isLayoutImage, isFalse);
      // A small PDF is never "layout", even inline.
      const pdf = FilePart(
        name: 'ticket.pdf',
        mimeType: 'application/pdf',
        size: 900,
        inline: true,
      );
      expect(pdf.isLayoutImage, isFalse);
    });

    test('hostile names are made safe', () {
      final files = FilePart.listFromImap(
        part(
          '',
          'multipart/mixed',
          children: [
            part(
              '1',
              'application/octet-stream',
              name: '../../invoice\u202Efdp.exe',
              disposition: 'attachment',
              size: 100,
            ),
          ],
        ),
      );
      expect(files.single.name, 'invoicefdp.exe');
    });
  });

  group('stored form', () {
    test('round trip', () {
      const file = FilePart(
        name: 'Résumé (final).pdf',
        mimeType: 'application/pdf',
        size: 52311,
        hasContentId: true,
      );
      expect(FilePart.decode(file.encode()), file);
    });

    test('anything else is not a file', () {
      expect(FilePart.decode('not json'), isNull);
      expect(FilePart.decode('[1, 2]'), isNull);
      expect(FilePart.decode('{"name": "a.pdf"}'), isNull);
      // A stored name is made safe again when read.
      expect(
        FilePart.decode(
          '{"name": "../x.pdf", "type": "application/pdf", "size": -4}',
        ),
        const FilePart(name: 'x.pdf', mimeType: 'application/pdf', size: 0),
      );
    });
  });

  group('from a downloaded message', () {
    test('cid images the text shows are not listed; attachments are', () {
      final view = MessageView.parse(
        Uint8List.fromList(
          raw([
            'From: Priya Raman <priya@studio.example>',
            'To: alice@citusmail.test',
            'Subject: Floor plan for Saturday',
            'MIME-Version: 1.0',
            'Content-Type: multipart/mixed; boundary="m"',
            '',
            '--m',
            'Content-Type: multipart/related; boundary="r"',
            '',
            '--r',
            'Content-Type: text/html; charset=utf-8',
            '',
            '<p>Here is the plan.</p><img src="cid:logo@studio">',
            '--r',
            'Content-Type: image/png; name="logo.png"',
            'Content-ID: <logo@studio>',
            'Content-Transfer-Encoding: base64',
            '',
            'iVBORw0KGgo=',
            '--r--',
            '--m',
            'Content-Type: application/pdf; name="Floor plan.pdf"',
            'Content-Disposition: attachment; filename="Floor plan.pdf"',
            'Content-Transfer-Encoding: base64',
            '',
            'JVBERi0xLjQK',
            '--m--',
            '',
          ]),
        ),
      );
      final files = FilePart.listFromView(view);
      expect(files.map((f) => f.name), ['Floor plan.pdf']);
      expect(files.single.kind, FileKind.pdf);
      expect(files.single.inline, isFalse);
    });
  });

  group('search', () {
    final words = FileSearch.words;

    test('every word must match the file, sender or subject', () {
      bool match(String text) => FileSearch.matches(
        words(text),
        fileName: 'Lease agreement.pdf',
        senderName: 'Harbour Lettings',
        senderAddress: 'tenancies@harbour-lettings.example',
        subject: 'Your new lease for Flat 4',
      );
      expect(match(''), isTrue);
      expect(match('lease'), isTrue);
      expect(match('LEASE harbour'), isTrue);
      expect(match('flat 4 pdf'), isTrue);
      expect(match('harbour-lettings.example'), isTrue);
      expect(match('lease invoice'), isFalse);
      expect(match('xlsx'), isFalse);
    });
  });
}
