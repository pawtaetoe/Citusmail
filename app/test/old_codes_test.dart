// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Opening an older verification email, whose code was never looked for,
// shows its code in the list from then on.

import 'dart:convert';
import 'dart:typed_data';

import 'package:citusmail/src/mail/mail_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  test('opening an old Uber code email fills in its code', () async {
    final store = app.store;
    final inbox = store.mailboxes.inbox(store.accounts.all().single.id)!;
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: 900,
        receivedAt: DateTime.utc(2026, 7, 18, 10, 33),
        subject: 'Your Uber account verification code',
        from: const MailAddress(localPart: 'admin', domain: 'uber.com'),
      ),
    ]);
    final message = store.messages.byUid(inbox.id, 900)!;
    store.messages.updateCategories([
      CategoryDecision(
        messageId: message.id,
        category: MessageCategory.codes,
        source: CategorySource.rule,
      ),
    ]);
    store.messages.saveBody(
      message.id,
      Uint8List.fromList(
        utf8.encode(
          'From: Uber <admin@uber.com>\r\n'
          'To: alice@citusmail.test\r\n'
          'Subject: Your Uber account verification code\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          '\r\n'
          'To finish logging in to your Uber account, enter this '
          'verification code:\r\n'
          'Do not share this code with anyone.\r\n'
          '\r\n'
          '9514\r\n',
        ),
      ),
      searchableText: 'Uber',
    );
    expect(store.messages.byId(message.id)!.code, isNull);

    final controller = MailController(app.services);
    addTearDown(controller.dispose);
    await controller.readerFor(store.messages.byId(message.id)!);
    expect(store.messages.byId(message.id)!.code, '9514');
  });
}
