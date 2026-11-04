// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'test_app.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

/// Made-up mail with attachments, for the Attachments page.
extension SampleFiles on TestApp {
  StoredMailbox _box(String name) => store.mailboxes
      .forAccount(store.accounts.all().single.id)
      .firstWhere((b) => b.encodedName == name);

  /// Mail with files across the inbox, Archive and Junk: most with names
  /// kept at sync, one only downloaded (its files read from the body),
  /// one neither (its files unknown).
  void seedFiles() {
    final now = DateTime.now().toUtc();
    DateTime ago(int days, [int hours = 0]) =>
        now.subtract(Duration(days: days, hours: hours));
    MessageSummary mail(
      int uid,
      DateTime at,
      String subject,
      String from,
      String name,
      List<FilePart> files, {
      MessageCategory category = MessageCategory.general,
      bool seen = true,
    }) => MessageSummary(
      uid: uid,
      receivedAt: at,
      subject: subject,
      from: _address(from, name),
      category: category,
      hasAttachments: true,
      flags: MessageFlags.fromImap([if (seen) r'\Seen']),
      headers: {
        if (files.isNotEmpty)
          FilePart.storedHeader: [for (final f in files) f.encode()],
      },
    );
    FilePart file(String name, String type, int kb, {bool cid = false}) =>
        FilePart(
          name: name,
          mimeType: type,
          size: kb * 1024,
          hasContentId: cid,
        );

    store.messages.upsertSummaries(_box('INBOX').id, [
      mail(
        400,
        ago(0, 2),
        'Lease for Flat 4, ready to sign',
        'tenancies@harbourlettings.example',
        'Harbour Lettings',
        [
          file('Lease agreement - Flat 4.pdf', 'application/pdf', 292),
          // The signature logo: not a file.
          file('image001.png', 'image/png', 9, cid: true),
        ],
        seen: false,
      ),
      mail(
        401,
        ago(1),
        'Photos from Saturday',
        'priya@studio.example',
        'Priya Raman',
        const [],
      ),
      mail(402, ago(3), 'Q3 budget, final numbers', 'dave@x.example', 'Dave', [
        file(
          'Q3 budget.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          48,
        ),
      ]),
      mail(
        403,
        ago(4),
        'Invitation: Design review, Thu 10:00',
        'calendar@x.example',
        'Calendar',
        [file('invite.ics', 'text/calendar', 3)],
        category: MessageCategory.notifications,
      ),
      mail(
        404,
        ago(6),
        'Your October statement is ready',
        'statements@northbank.example',
        'Northbank',
        [file('Statement 2026-10.pdf', 'application/pdf', 118)],
        category: MessageCategory.notifications,
      ),
      mail(
        405,
        ago(8),
        'Contract draft for review',
        'marco@lawfirm.example',
        'Marco Bianchi',
        [
          file('Contract draft v3.docx', 'application/msword', 64),
          file('Changes since v2.pdf', 'application/pdf', 35),
        ],
      ),
      mail(
        406,
        ago(10),
        'Weekly deals: up to 40% off',
        'news@shop.example',
        'Shop',
        [file('Autumn catalogue.pdf', 'application/pdf', 2400)],
        category: MessageCategory.newsletters,
      ),
      mail(
        407,
        ago(12),
        'Overdue invoice',
        'billing@invoices.example',
        'Accounts Dept',
        [file('invoice.pdf.exe', 'application/octet-stream', 210)],
      ),
      mail(
        408,
        ago(30),
        'Old project files',
        'erik@x.example',
        'Erik',
        const [],
      ),
    ]);
    store.messages.upsertSummaries(_box('Archive').id, [
      mail(
        409,
        ago(41),
        'Your 2025 tax return',
        'office@accountants.example',
        'Lim & Co Accountants',
        [
          file('Tax return 2025.pdf', 'application/pdf', 820),
          file('Receipts 2025.zip', 'application/zip', 5300),
        ],
      ),
    ]);
    store.messages.upsertSummaries(_box('Junk').id, [
      mail(
        410,
        ago(0, 1),
        'You have won!',
        'prize@lottery.example',
        'Prize Desk',
        [file('claim form.pdf', 'application/pdf', 40)],
      ),
    ]);

    // Downloaded before file names were kept: read from the body.
    final photos = store.messages.byUid(_box('INBOX').id, 401)!;
    store.messages.saveBody(
      photos.id,
      _photosMessage(),
      searchableText: 'Here are the photos',
    );
  }
}

/// A message with two photos and a signature logo shown by Content-ID.
Uint8List _photosMessage() {
  String b64(List<int> bytes) => base64
      .encode(bytes)
      .replaceAllMapped(RegExp('.{76}'), (m) => '${m[0]}\r\n');
  final lines = [
    'From: Priya Raman <priya@studio.example>',
    'To: alice@citusmail.test',
    'Subject: Photos from Saturday',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="m"',
    '',
    '--m',
    'Content-Type: multipart/related; boundary="r"',
    '',
    '--r',
    'Content-Type: text/html; charset=utf-8',
    '',
    '<p>Here are the photos from Saturday!</p><p>Priya</p>',
    '<img src="cid:logo@studio" width="80">',
    '--r',
    'Content-Type: image/png; name="logo.png"',
    'Content-ID: <logo@studio>',
    'Content-Transfer-Encoding: base64',
    '',
    b64(samplePng(16, 16, 0)),
    '--r--',
    for (final (i, name) in ['Beach.png', 'Sunset.png'].indexed) ...[
      '--m',
      'Content-Type: image/png; name="$name"',
      'Content-Disposition: attachment; filename="$name"',
      'Content-Transfer-Encoding: base64',
      '',
      b64(samplePng(96, 96, i + 1)),
    ],
    '--m--',
    '',
  ];
  return Uint8List.fromList(utf8.encode(lines.join('\r\n')));
}

/// A real PNG of [width] x [height]: a soft gradient with some grain
/// ([seed] picks the colours), big enough not to count as a logo.
Uint8List samplePng(int width, int height, int seed) {
  final random = Random(seed);
  final palettes = [
    ([40, 90, 160], [240, 200, 120]),
    ([30, 140, 200], [250, 230, 170]),
    ([220, 90, 60], [70, 40, 120]),
  ];
  final (top, bottom) = palettes[seed % palettes.length];
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // no filter
    for (var x = 0; x < width; x++) {
      final t = (y + x * 0.3) / (height + width * 0.3);
      for (var c = 0; c < 3; c++) {
        final v = top[c] + (bottom[c] - top[c]) * t + random.nextInt(24) - 12;
        raw.addByte(v.round().clamp(0, 255));
      }
    }
  }
  Uint8List chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    return Uint8List.fromList([
      ..._be32(data.length),
      ...body,
      ..._be32(_crc32(body)),
    ]);
  }

  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', [
      ..._be32(width),
      ..._be32(height),
      8, 2, 0, 0, 0, // 8-bit RGB
    ]),
    ...chunk('IDAT', ZLibCodec().encode(raw.toBytes())),
    ...chunk('IEND', const []),
  ]);
}

List<int> _be32(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = crc & 1 != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
