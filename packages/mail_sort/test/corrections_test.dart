// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

const shop = MailAddress(
  displayName: 'Shop',
  localPart: 'news',
  domain: 'shop.example',
);
const henry = MailAddress(localPart: 'henry', domain: 'project.example');
const bank = MailAddress(localPart: 'no-reply', domain: 'bank.example');
const listHeader = {
  'list-id': ['Project developers <dev.lists.project.example>'],
};

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
    inbox = boxes.firstWhere((b) => b.encodedName == 'INBOX');
    sent = boxes.firstWhere((b) => b.encodedName == 'Sent');
  });

  tearDown(() {
    store.close();
    directory.deleteSync(recursive: true);
  });

  /// Stores a message the way sync does: classified by the header rules.
  StoredMessage receive(
    int uid,
    MailAddress from, {
    Map<String, List<String>> headers = const {},
    StoredMailbox? into,
  }) {
    final box = into ?? inbox;
    final decision = const HeaderRuleClassifier().classify(
      ClassificationInput(
        from: from,
        headers: headers,
        mailboxUse: box.specialUse,
      ),
    );
    store.messages.upsertSummaries(box.id, [
      MessageSummary(
        uid: uid,
        receivedAt: DateTime.utc(2026, 10, 1, 0, uid),
        from: from,
        headers: headers,
        category: decision.category,
        categorySource: decision.source,
        listId: ListId.fromHeaders(headers),
      ),
    ]);
    return store.messages.byUid(box.id, uid)!;
  }

  StoredMessage reload(StoredMessage m) => store.messages.byId(m.id)!;

  group('corrections', () {
    late CategoryCorrections corrections;
    setUp(() => corrections = CategoryCorrections(store));

    test('moving a message moves its sender, earlier and later', () {
      final first = receive(1, bank);
      final other = receive(2, henry);
      expect(first.category, MessageCategory.notifications);

      final choice = corrections.move(first, MessageCategory.people)!.choice;
      expect(choice.scope, ChoiceScope.sender);
      expect(choice.key, 'no-reply@bank.example');
      expect(reload(first).category, MessageCategory.people);
      expect(reload(first).categorySource, CategorySource.manual);
      expect(reload(other).categorySource, CategorySource.rule);

      final later = receive(3, bank);
      expect(later.category, MessageCategory.people);
      expect(corrections.choiceFor(later), choice);
    });

    test('moving a list message moves the whole list, not the poster', () {
      final post = receive(1, henry, headers: listHeader);
      final otherPoster = receive(2, shop, headers: listHeader);
      final direct = receive(3, henry);
      expect(post.listId, 'dev.lists.project.example');
      expect(post.category, MessageCategory.newsletters);

      final choice = corrections.move(post, MessageCategory.people)!.choice;
      expect(choice.scope, ChoiceScope.list);
      expect(reload(otherPoster).category, MessageCategory.people);
      expect(reload(direct).categorySource, CategorySource.rule);
    });

    test('undo brings back the rules, then any sender choice', () {
      final post = receive(1, henry, headers: listHeader);
      corrections.move(receive(2, henry), MessageCategory.notifications);
      corrections.move(post, MessageCategory.people);
      expect(reload(post).category, MessageCategory.people);

      expect(corrections.undo(reload(post))!.scope, ChoiceScope.list);
      expect(reload(post).category, MessageCategory.notifications); // Henry
      expect(corrections.undo(reload(post))!.scope, ChoiceScope.sender);
      expect(reload(post).category, MessageCategory.newsletters); // rules
      expect(reload(post).categorySource, CategorySource.rule);
      expect(corrections.undo(reload(post)), isNull);
    });

    test('forget removes a choice from a settings list', () {
      final m = receive(1, shop);
      final choice = corrections.move(m, MessageCategory.newsletters)!.choice;
      expect(store.categoryChoices.all(), [choice]);
      expect(corrections.forget(choice), isTrue);
      expect(corrections.forget(choice), isFalse);
      expect(reload(m).category, MessageCategory.people);
    });

    test('revert undoes a move exactly, including a replaced choice', () {
      final m = receive(1, bank);
      final firstMove = corrections.move(m, MessageCategory.people)!;
      expect(firstMove.replaced, isNull);
      final secondMove = corrections.move(
        reload(m),
        MessageCategory.newsletters,
      )!;
      expect(secondMove.replaced, firstMove.choice);
      expect(reload(m).category, MessageCategory.newsletters);

      corrections.revert(secondMove);
      expect(reload(m).category, MessageCategory.people);
      expect(store.categoryChoices.all(), [firstMove.choice]);
      corrections.revert(firstMove);
      expect(reload(m).category, MessageCategory.notifications);
      expect(store.categoryChoices.all(), isEmpty);
    });

    test('a message without sender or list cannot teach anything', () {
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(uid: 9, receivedAt: DateTime.utc(2026)),
      ]);
      final anonymous = store.messages.byUid(inbox.id, 9)!;
      expect(CategoryCorrections.targetOf(anonymous), isNull);
      expect(corrections.move(anonymous, MessageCategory.people), isNull);
      expect(corrections.choiceFor(anonymous), isNull);
      expect(store.categoryChoices.all(), isEmpty);
    });
  });

  group('re-sorting stored mail', () {
    /// Simulates mail stored by an older version that sorted everything
    /// into People and kept no list id.
    StoredMessage storeUnsorted(
      int uid,
      MailAddress from,
      Map<String, List<String>> headers, {
      StoredMailbox? into,
    }) {
      store.messages.upsertSummaries((into ?? inbox).id, [
        MessageSummary(
          uid: uid,
          receivedAt: DateTime.utc(2026, 10, 1, 0, uid),
          from: from,
          headers: headers,
        ),
      ]);
      return store.messages.byUid((into ?? inbox).id, uid)!;
    }

    test('sorts old mail from stored headers once, keeping choices', () async {
      final news = storeUnsorted(1, shop, {
        'list-unsubscribe': ['<https://shop.example/u>'],
        'list-unsubscribe-post': ['List-Unsubscribe=One-Click'],
      });
      final alert = storeUnsorted(2, bank, const {});
      final post = storeUnsorted(3, henry, listHeader);
      final mine = storeUnsorted(4, bank, const {}, into: sent);
      final friend = storeUnsorted(5, henry, const {});
      store.categoryChoices.save(
        CategoryChoice(
          scope: ChoiceScope.sender,
          key: henry.address,
          category: MessageCategory.notifications,
        ),
      );
      for (final m in [news, alert, mine]) {
        expect(reload(m).category, MessageCategory.people);
      }

      final resorter = Resorter(store, batchSize: 2); // several batches
      expect(resorter.isNeeded, isTrue);
      expect(await resorter.resortIfNeeded(), 5);
      expect(resorter.isNeeded, isFalse);
      expect(await resorter.resortIfNeeded(), 0);

      expect(reload(news).category, MessageCategory.newsletters);
      expect(reload(alert).category, MessageCategory.notifications);
      expect(reload(mine).category, MessageCategory.people); // in Sent
      expect(reload(friend).category, MessageCategory.notifications); // chosen
      expect(reload(post).listId, 'dev.lists.project.example');
      expect(
        reload(post).category,
        MessageCategory.notifications,
      ); // Henry's choice
      store.categoryChoices.remove(ChoiceScope.sender, henry.address);
      expect(reload(post).category, MessageCategory.newsletters);
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
      expect(await Resorter(store).resortIfNeeded(), 0);
      expect(
        store.settings.read(Resorter.versionKey),
        '${HeaderRuleClassifier.currentVersion}',
      );
    });
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
