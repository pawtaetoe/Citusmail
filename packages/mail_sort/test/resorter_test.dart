// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

const shop = MailAddress(localPart: 'news', domain: 'shop.example');
const bank = MailAddress(localPart: 'no-reply', domain: 'bank.example');
const henry = MailAddress(localPart: 'henry', domain: 'project.example');

void main() {
  late Directory directory;
  late MailStore store;
  late StoredMailbox inbox;
  late StoredMailbox sent;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mail_sort_test');
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
      ImapMailboxInfo(
        encodedName: 'INBOX',
        delimiter: '/',
        attributes: const {},
      ),
      ImapMailboxInfo(
        encodedName: 'Sent',
        delimiter: '/',
        attributes: const {r'\Sent'},
      ),
    ]);
    inbox = boxes.firstWhere((b) => b.isInbox);
    sent = boxes.firstWhere((b) => b.specialUse == SpecialUse.sent);
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  /// Mail stored by an older version: everything General, no list id.
  StoredMessage storeUnsorted(
    int uid,
    MailAddress from,
    Map<String, List<String>> headers, {
    StoredMailbox? into,
  }) {
    final box = into ?? inbox;
    store.messages.upsertSummaries(box.id, [
      MessageSummary(
        uid: uid,
        receivedAt: DateTime.utc(2026, 10, 1, 0, uid),
        from: from,
        headers: headers,
      ),
    ]);
    return store.messages.byUid(box.id, uid)!;
  }

  StoredMessage reload(StoredMessage m) => store.messages.byId(m.id)!;

  test('sorts stored mail from its headers once', () async {
    final news = storeUnsorted(1, shop, {
      'list-unsubscribe': ['<https://shop.example/u>'],
      'list-unsubscribe-post': ['List-Unsubscribe=One-Click'],
    });
    final alert = storeUnsorted(2, bank, const {});
    final post = storeUnsorted(3, henry, {
      'list-id': ['Project developers <dev.lists.project.example>'],
    });
    final mine = storeUnsorted(4, bank, const {}, into: sent);
    final friend = storeUnsorted(5, henry, const {});

    final resorter = Resorter(store, batchSize: 2); // several batches
    expect(resorter.isNeeded, isTrue);
    expect(await resorter.resortIfNeeded(), 5);
    expect(resorter.isNeeded, isFalse);
    expect(await resorter.resortIfNeeded(), 0);

    expect(reload(news).category, MessageCategory.newsletters);
    expect(reload(alert).category, MessageCategory.notifications);
    expect(reload(post).category, MessageCategory.newsletters);
    expect(reload(post).listId, 'dev.lists.project.example');
    expect(reload(mine).category, MessageCategory.general); // in Sent
    expect(reload(friend).category, MessageCategory.general);
  });

  test('runs again when the rules version changes', () async {
    storeUnsorted(1, shop, const {});
    await Resorter(store).resortIfNeeded();
    final newer = Resorter(store, classifier: const _FixedClassifier(99));
    expect(newer.isNeeded, isTrue);
    expect(await newer.resortIfNeeded(), 1);
    expect(
      store.messages.byUid(inbox.id, 1)!.category,
      MessageCategory.notifications,
    );
    expect(store.settings.read(Resorter.versionKey), '99');
  });

  test('an empty store just records the version', () async {
    final resorter = Resorter(store);
    expect(await resorter.resortIfNeeded(), 0);
    expect(
      store.settings.read(Resorter.versionKey),
      '${resorter.classifier.version}',
    );
    expect(
      resorter.classifier,
      isA<LearnedClassifier>(),
      reason: 'the same sorting as sync',
    );
  });
}

final class _FixedClassifier implements MessageClassifier {
  const _FixedClassifier(this.version);

  @override
  final int version;

  @override
  Classification classify(ClassificationInput input) => const Classification(
    MessageCategory.notifications,
    SortingReason.noSignal,
  );
}
