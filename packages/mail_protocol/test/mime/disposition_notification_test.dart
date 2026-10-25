// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

MimeMessage _fixture(String path) => const MimeParser().parse(
  File('../../test-data/mail/$path').readAsBytesSync(),
);

void main() {
  test('reads the receipt fixture', () {
    final n = DispositionNotification.fromMessage(
      _fixture('receipts/mdn-displayed.eml'),
    )!;
    expect(n.originalMessageId, 'alice-report-1@citusmail.test');
    expect(n.finalRecipient, 'bob@citusmail.test');
    expect(n.disposition, 'displayed');
    expect(n.displayed, isTrue);
  });

  test('ordinary mail and other reports are not receipts', () {
    expect(
      DispositionNotification.fromMessage(_fixture('people/plain-text.eml')),
      isNull,
    );
    final delivery = const MimeParser().parse(
      Uint8List.fromList(
        utf8.encode(
          'Content-Type: multipart/report; report-type=delivery-status; boundary=b\r\n\r\n'
          '--b\r\nContent-Type: message/delivery-status\r\n\r\nAction: failed\r\n--b--\r\n',
        ),
      ),
    );
    expect(DispositionNotification.fromMessage(delivery), isNull);
  });

  test('fields: folding, case, angle brackets, other dispositions', () {
    final n = DispositionNotification.parseFields(
      'final-recipient: RFC822; <Bob@Example.COM>\n'
      'ORIGINAL-MESSAGE-ID:\n <abc@x.example>\n'
      'Disposition: automatic-action/MDN-sent-automatically; deleted\n',
    )!;
    expect(n.finalRecipient, 'bob@example.com');
    expect(n.originalMessageId, 'abc@x.example');
    expect(n.disposition, 'deleted');
    expect(n.displayed, isFalse);
  });

  test('incomplete or odd notifications are refused', () {
    for (final text in [
      '',
      'Final-Recipient: rfc822;bob@x.example\nDisposition: a/b; displayed',
      'Original-Message-ID: <a@b>\nDisposition: a/b; displayed',
      'Original-Message-ID: <a@b>\nFinal-Recipient: rfc822;bob@x.example\nDisposition: a/b; exploded',
      'Original-Message-ID: <a b@c>\nFinal-Recipient: rfc822;bob@x.example\nDisposition: a/b; displayed',
      'Original-Message-ID: <a@b>\nFinal-Recipient: rfc822;nobody\nDisposition: a/b; displayed',
    ]) {
      expect(DispositionNotification.parseFields(text), isNull, reason: text);
    }
  });

  test('asking for a receipt writes the standard header, nothing more', () {
    final built = MessageBuilder().build(
      OutgoingMessage(
        from: const MailAddress(
          localPart: 'alice',
          domain: 'citusmail.test',
          displayName: 'Alice',
        ),
        to: const [MailAddress(localPart: 'bob', domain: 'citusmail.test')],
        subject: 'Report',
        textBody: 'Hi',
        receiptTo: const MailAddress(
          localPart: 'alice',
          domain: 'citusmail.test',
        ),
      ),
    );
    final text = ascii.decode(built.bytes);
    expect(
      text,
      matches(
        RegExp(r'Disposition-Notification-To: <?alice@citusmail\.test>?\r\n'),
      ),
    );
    final plain = ascii.decode(
      MessageBuilder()
          .build(
            OutgoingMessage(
              from: const MailAddress(
                localPart: 'alice',
                domain: 'citusmail.test',
              ),
              to: const [
                MailAddress(localPart: 'bob', domain: 'citusmail.test'),
              ],
              textBody: 'Hi',
            ),
          )
          .bytes,
    );
    expect(plain, isNot(contains('Disposition-Notification-To')));
  });
}
