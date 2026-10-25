// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

const _shop = MailAddress(localPart: 'hello', domain: 'shop.example');
const _friend = MailAddress(localPart: 'sam', domain: 'friend.example');

const _newsletter = {
  'list-unsubscribe': ['<https://shop.example/u>'],
  'list-unsubscribe-post': ['List-Unsubscribe=One-Click'],
};

void main() {
  late Directory directory;
  late MailStore store;
  late StoredMailbox inbox;
  late StoredMailbox sent;
  late DateTime now;
  var uid = 0;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('learned_test');
    store = MailStore.open('${directory.path}/mail.db', DatabaseKey.generate());
    final account = store.accounts.add(
      NewAccount(
        email: 'alice@fmail.test',
        username: 'alice',
        imap: ServerSettings(
          host: 'h.example',
          port: 993,
          security: ConnectionSecurity.implicitTls,
        ),
        smtp: ServerSettings(
          host: 'h.example',
          port: 465,
          security: ConnectionSecurity.implicitTls,
        ),
      ),
    );
    final boxes = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
      ImapMailboxInfo(
        encodedName: 'Sent',
        delimiter: '/',
        attributes: {r'\Sent'},
      ),
    ]);
    inbox = boxes.firstWhere((b) => b.isInbox);
    sent = boxes.firstWhere((b) => b.specialUse == SpecialUse.sent);
    now = DateTime.utc(2026, 10, 25);
    uid = 0;
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  void receive(
    MailAddress from, [
    Map<String, List<String>> headers = const {},
  ]) => store.messages.upsertSummaries(inbox.id, [
    MessageSummary(
      uid: ++uid,
      receivedAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: uid)),
      from: from,
      headers: headers,
    ),
  ]);

  LearnedClassifier classifier() => LearnedClassifier(
    const HeaderRuleClassifier(),
    StoreSenderHistory(store),
    now: () => now,
  );

  Classification classify(
    LearnedClassifier c,
    MailAddress from, [
    Map<String, List<String>> headers = const {},
  ]) => c.classify(ClassificationInput(from: from, headers: headers));

  test('mail without a signal follows the sender\'s clear pattern', () {
    for (var i = 0; i < 3; i++) {
      receive(_shop, _newsletter);
    }
    final decision = classify(classifier(), _shop);
    expect(decision.category, MessageCategory.newsletters);
    expect(decision.reason, SortingReason.sameSender);
  });

  test('rule decisions always win', () {
    for (var i = 0; i < 5; i++) {
      receive(_shop, _newsletter);
    }
    final decision = classify(classifier(), _shop, {
      'auto-submitted': ['auto-replied'],
    });
    expect(decision.reason, SortingReason.autoReply);
    expect(decision.category, MessageCategory.general);
  });

  test('too little or mixed evidence keeps General', () {
    receive(_shop, _newsletter);
    receive(_shop, _newsletter);
    expect(classify(classifier(), _shop).reason, SortingReason.noSignal);

    // Three newsletters, but also personal mail from the same address.
    receive(_shop, _newsletter);
    receive(_shop);
    expect(
      classify(classifier(), _shop).category,
      MessageCategory.general,
      reason: '3 of 4 is not clear enough',
    );
  });

  test('never for people the user writes to', () {
    for (var i = 0; i < 4; i++) {
      receive(_friend, {
        'list-id': ['Book club <club.friend.example>'],
      });
    }
    expect(
      classify(classifier(), _friend).category,
      MessageCategory.newsletters,
    );
    store.messages.upsertSummaries(sent.id, [
      MessageSummary(
        uid: 1,
        receivedAt: DateTime.utc(2026, 10, 2),
        from: const MailAddress(localPart: 'alice', domain: 'fmail.test'),
        to: const [MailAddress(localPart: 'SAM', domain: 'friend.example')],
      ),
    ]);
    expect(
      classify(classifier(), _friend).category,
      MessageCategory.general,
      reason: 'alice wrote to sam',
    );
  });

  test('senders are looked up again after a while', () {
    final c = classifier();
    expect(classify(c, _shop).reason, SortingReason.noSignal);
    for (var i = 0; i < 3; i++) {
      receive(_shop, _newsletter);
    }
    expect(classify(c, _shop).reason, SortingReason.noSignal, reason: 'cached');
    now = now.add(const Duration(minutes: 11));
    expect(classify(c, _shop).reason, SortingReason.sameSender);
  });

  test('the version changes with the rules', () {
    expect(classifier().version, HeaderRuleClassifier.currentVersion * 100 + 1);
  });
}
