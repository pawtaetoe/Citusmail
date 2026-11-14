// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

/// A broker's security team, writing from a person-like address (a
/// `noreply` one would be a notification by the rules).
const _broker = MailAddress(
  localPart: 'security',
  domain: 'broker.example',
  displayName: 'Example Broker',
);
const _person = MailAddress(
  localPart: 'jo',
  domain: 'family.example',
  displayName: 'Jo',
);
const _shop = MailAddress(localPart: 'hello', domain: 'shop.example');

const _newsletter = {
  'list-unsubscribe': ['<https://shop.example/u>'],
  'list-unsubscribe-post': ['List-Unsubscribe=One-Click'],
};

void main() {
  group('Classification.unsure', () {
    const rules = HeaderRuleClassifier();

    test('only when the rules found no signal', () {
      final plain = rules.classify(
        const ClassificationInput(
          from: _person,
          headers: {},
          subject: 'Lunch on Sunday?',
        ),
      );
      expect(plain.category, MessageCategory.general);
      expect(plain.unsure, isTrue);

      final list = rules.classify(
        const ClassificationInput(
          from: _shop,
          headers: _newsletter,
          subject: 'Autumn sale',
        ),
      );
      expect(list.unsure, isFalse);

      final code = rules.classify(
        const ClassificationInput(
          from: _shop,
          headers: {},
          subject: 'Your verification code',
        ),
      );
      expect(code.unsure, isFalse);

      final own = rules.classify(
        const ClassificationInput(
          from: _person,
          headers: {},
          mailboxUse: SpecialUse.sent,
        ),
      );
      expect(own.category, MessageCategory.general);
      expect(own.unsure, isFalse, reason: 'General because it is sent mail');
    });

    test('learned and AI decisions are not unsure', () {
      expect(
        const Classification(
          MessageCategory.notifications,
          SortingReason.sameSender,
        ).unsure,
        isFalse,
      );
      expect(
        const Classification(MessageCategory.codes, SortingReason.ai).unsure,
        isFalse,
      );
    });
  });

  group('AiSortAnswer.parse', () {
    test('a valid answer', () {
      final answer = AiSortAnswer.parse({
        'category': 'notifications',
        'reason': 'An automatic account notice from a broker.',
        'isVerification': false,
      })!;
      expect(answer.category, MessageCategory.notifications);
      expect(answer.decided, MessageCategory.notifications);
      expect(answer.reason, 'An automatic account notice from a broker.');
    });

    test('verification mail goes to Codes whatever the category', () {
      final answer = AiSortAnswer.parse({
        'category': 'notifications',
        'reason': 'A security notice with a code to verify a log in.',
        'isVerification': true,
      })!;
      expect(answer.decided, MessageCategory.codes);
    });

    test('anything but the schema is ignored', () {
      Map<String, Object?> valid() => {
        'category': 'newsletters',
        'reason': 'Marketing.',
        'isVerification': false,
      };
      expect(AiSortAnswer.parse(valid()), isNotNull);
      expect(AiSortAnswer.parse(null), isNull);
      expect(AiSortAnswer.parse({}), isNull);
      // Not a category the app has.
      expect(AiSortAnswer.parse(valid()..['category'] = 'important'), isNull);
      expect(AiSortAnswer.parse(valid()..['category'] = 'Newsletters'), isNull);
      expect(AiSortAnswer.parse(valid()..['category'] = 'spam'), isNull);
      expect(AiSortAnswer.parse(valid()..['category'] = 3), isNull);
      // Wrong types, missing or empty.
      expect(AiSortAnswer.parse(valid()..['isVerification'] = 'yes'), isNull);
      expect(AiSortAnswer.parse(valid()..remove('isVerification')), isNull);
      expect(AiSortAnswer.parse(valid()..['reason'] = '  \n '), isNull);
      expect(AiSortAnswer.parse(valid()..['reason'] = null), isNull);
      // Something more than asked for: an action, a reply, a forward.
      expect(
        AiSortAnswer.parse(valid()..['forwardTo'] = 'attacker@evil.example'),
        isNull,
      );
    });

    test('the reason is one short line without hidden characters', () {
      final zeroWidth = String.fromCharCode(0x200B);
      final rightToLeft = String.fromCharCode(0x202E);
      final answer = AiSortAnswer.parse({
        'category': 'general',
        'reason':
            'A note\nfrom$zeroWidth a friend$rightToLeft.\t'
            '${'very ' * 60}long',
        'isVerification': false,
      })!;
      expect(answer.reason, startsWith('A note from a friend. very very'));
      expect(answer.reason, isNot(contains('\n')));
      expect(answer.reason, isNot(contains(zeroWidth)));
      expect(answer.reason, isNot(contains(rightToLeft)));
      expect(answer.reason.length, AiSortAnswer.maxReason);
      expect(answer.reason, endsWith('…'));
    });

    test('the schema lists exactly the categories it accepts', () {
      final properties = AiSortAnswer.schema['properties']! as Map;
      final category = properties['category'] as Map;
      expect(
        (category['enum'] as List).toSet(),
        AiSortAnswer.categoryNames.keys.toSet(),
      );
      expect(
        AiSortAnswer.categoryNames.values.toSet(),
        MessageCategory.values.toSet(),
      );
      expect(AiSortAnswer.schema['additionalProperties'], isFalse);
    });
  });

  group('with a store', () {
    late Directory directory;
    late MailStore store;
    late StoredMailbox inbox;
    late StoredMailbox sent;
    final now = DateTime.utc(2026, 11, 14, 12);
    var uid = 0;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('ai_sorting_test');
      store = MailStore.open(
        '${directory.path}/mail.db',
        DatabaseKey.generate(),
      );
      final account = store.accounts.add(
        NewAccount(
          email: 'alice@citusmail.test',
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
      uid = 0;
    });

    tearDown(() {
      store.close();
      directory.deleteSync(recursive: true);
    });

    /// Stores a message as sync would: sorted by the same rules.
    StoredMessage receive(
      MailAddress from,
      String subject, {
      Map<String, List<String>> headers = const {},
      Duration ago = const Duration(minutes: 5),
      StoredMailbox? into,
      List<MailAddress> to = const [],
    }) {
      final box = into ?? inbox;
      final decision = const HeaderRuleClassifier().classify(
        ClassificationInput(
          from: from,
          headers: headers,
          subject: subject,
          mailboxUse: box.specialUse,
        ),
      );
      store.messages.upsertSummaries(box.id, [
        MessageSummary(
          uid: ++uid,
          receivedAt: now.subtract(ago),
          from: from,
          to: to,
          subject: subject,
          headers: headers,
          category: decision.category,
          listId: ListId.fromHeaders(headers),
        ),
      ]);
      return store.messages.byUid(box.id, uid)!;
    }

    List<int> candidates({int limit = 20}) => [
      for (final m in AiSortCandidates.find(store, now: now, limit: limit))
        m.id,
    ];

    group('AiSortCandidates', () {
      test('new mail the rules are unsure about, newest first', () {
        final older = receive(
          _broker,
          'Security Notice',
          ago: const Duration(hours: 3),
        );
        final newer = receive(_shop, 'Your order is on its way');
        expect(candidates(), [newer.id, older.id]);
      });

      test('never mail the rules decided', () {
        receive(_shop, 'Autumn sale', headers: _newsletter);
        receive(_shop, 'Your login code is 551200');
        receive(
          const MailAddress(localPart: 'noreply', domain: 'bank.example'),
          'Statement ready',
        );
        expect(candidates(), isEmpty);
      });

      test('not mail older than a day, nor sent mail', () {
        receive(_broker, 'Security Notice', ago: const Duration(hours: 25));
        receive(_person, 'Re: lunch', into: sent);
        expect(candidates(), isEmpty);
      });

      test('not mail from people the user writes to (Important)', () {
        receive(_broker, 'Hello', into: sent, to: [_person]);
        final fromJo = receive(_person, 'Lunch on Sunday?');
        expect(fromJo.section, SmartSection.important);
        expect(candidates(), isEmpty);
      });

      test('never a message asked about before', () {
        final asked = receive(_broker, 'Security Notice');
        final fresh = receive(_shop, 'Thanks for your order');
        AiSortLog(store).add(
          AiSortEntry(
            messageId: asked.id,
            outcome: AiSortOutcome.ignored,
            at: now,
          ),
        );
        expect(candidates(), [fresh.id]);
      });

      test('at most the limit', () {
        for (var i = 0; i < 5; i++) {
          receive(_shop, 'Order $i');
        }
        expect(candidates(limit: 2), hasLength(2));
        expect(candidates(limit: 0), isEmpty);
      });
    });

    group('AiSortLog', () {
      AiSortEntry entry(int id, [AiSortOutcome o = AiSortOutcome.applied]) =>
          AiSortEntry(
            messageId: id,
            outcome: o,
            at: now,
            category: MessageCategory.codes,
            reason: 'A sign-in code.',
            verification: true,
            by: 'Anthropic',
            sender: 'security@broker.example',
          );

      test('remembers what was asked and decided', () {
        final log = AiSortLog(store);
        expect(log.entries, isEmpty);
        log
          ..add(entry(1))
          ..add(entry(2, AiSortOutcome.ignored));
        expect(log.asked, {1, 2});
        expect(log.applied().keys, [1]);
        final one = log.forMessage(1)!;
        expect(one.category, MessageCategory.codes);
        expect(one.reason, 'A sign-in code.');
        expect(one.verification, isTrue);
        expect(one.by, 'Anthropic');
        expect(one.sender, 'security@broker.example');
        expect(one.at, now);
      });

      test('undo: no longer applied, still never asked again', () {
        final log = AiSortLog(store)..add(entry(1));
        log.undo(1);
        expect(log.applied(), isEmpty);
        expect(log.asked, {1});
        expect(log.forMessage(1)!.outcome, AiSortOutcome.undone);
        expect(log.entries, hasLength(1));
      });

      test('keeps the newest entries only', () {
        final log = AiSortLog(store);
        for (var i = 1; i <= AiSortLog.keep + 3; i++) {
          log.add(entry(i, AiSortOutcome.kept));
        }
        expect(log.entries, hasLength(AiSortLog.keep));
        expect(log.asked, isNot(contains(1)));
        expect(log.asked, contains(AiSortLog.keep + 3));
      });

      test('a correction stays in force, with the user\'s category', () {
        final log = AiSortLog(store)..add(entry(1));
        log.correct(1, MessageCategory.notifications);
        final corrected = log.applied()[1]!;
        expect(corrected.outcome, AiSortOutcome.corrected);
        expect(corrected.category, MessageCategory.notifications);
        expect(log.asked, {1});
        // Nothing to correct for a message never asked about.
        log.correct(2, MessageCategory.general);
        expect(log.asked, {1});
      });

      test('a damaged setting reads as empty', () {
        store.settings.write(AiSortLog.key, '{not json');
        expect(AiSortLog(store).entries, isEmpty);
        store.settings.write(AiSortLog.key, '[{"id":"x"}, 7]');
        expect(AiSortLog(store).entries, isEmpty);
      });
    });

    group('Resorter', () {
      test('keeps an AI decision while the rules stay unsure', () async {
        final notice = receive(_broker, 'Security Notice');
        store.messages.updateCategories([
          CategoryDecision(
            messageId: notice.id,
            category: MessageCategory.codes,
            source: CategorySource.rule,
          ),
        ]);
        AiSortLog(store).add(
          AiSortEntry(
            messageId: notice.id,
            outcome: AiSortOutcome.applied,
            at: now,
            category: MessageCategory.codes,
          ),
        );
        await Resorter(store).resortAll();
        expect(store.messages.byId(notice.id)!.category, MessageCategory.codes);
      });

      test('the rules win once they have a signal', () async {
        final news = receive(_shop, 'Autumn sale', headers: _newsletter);
        AiSortLog(store).add(
          AiSortEntry(
            messageId: news.id,
            outcome: AiSortOutcome.applied,
            at: now,
            category: MessageCategory.general,
          ),
        );
        await Resorter(store).resortAll();
        expect(
          store.messages.byId(news.id)!.category,
          MessageCategory.newsletters,
        );
      });

      test('the user\'s correction wins over the assistant', () async {
        final notice = receive(_broker, 'Security Notice');
        AiSortLog(store)
          ..add(
            AiSortEntry(
              messageId: notice.id,
              outcome: AiSortOutcome.applied,
              at: now,
              category: MessageCategory.codes,
            ),
          )
          ..correct(notice.id, MessageCategory.notifications);
        await Resorter(store).resortAll();
        expect(
          store.messages.byId(notice.id)!.category,
          MessageCategory.notifications,
        );
      });

      test('an undone decision no longer applies', () async {
        final notice = receive(_broker, 'Security Notice');
        AiSortLog(store)
          ..add(
            AiSortEntry(
              messageId: notice.id,
              outcome: AiSortOutcome.applied,
              at: now,
              category: MessageCategory.codes,
            ),
          )
          ..undo(notice.id);
        await Resorter(store).resortAll();
        expect(
          store.messages.byId(notice.id)!.category,
          MessageCategory.general,
        );
      });
    });

    group('SenderSortChoices', () {
      Classification classify(MailAddress from, String subject) =>
          LearnedClassifier(
            const HeaderRuleClassifier(),
            StoreSenderHistory(store),
          ).classify(
            ClassificationInput(
              from: from,
              headers: const {},
              subject: subject,
            ),
          );

      test('the sender\'s next unsure mail follows the user', () {
        expect(classify(_broker, 'Account update').unsure, isTrue);
        SenderSortChoices(store)
            .choose('Security@Broker.example', MessageCategory.notifications);
        final next = classify(_broker, 'Account update');
        expect(next.category, MessageCategory.notifications);
        expect(next.reason, SortingReason.userChoice);
        expect(next.unsure, isFalse);
        // So it is not offered to the assistant.
        receive(_broker, 'Account update');
        expect(candidates(), isEmpty);
      });

      test('General is a choice too: never asked about again', () {
        SenderSortChoices(store).choose(_shop.address, MessageCategory.general);
        receive(_shop, 'A note from the shop owner');
        expect(candidates(), isEmpty);
      });

      test('the rules still come first', () {
        SenderSortChoices(store).choose(_shop.address, MessageCategory.general);
        final code = classify(_shop, 'Your verification code');
        expect(code.category, MessageCategory.codes);
        expect(code.reason, SortingReason.verification);
      });

      test('Codes are never kept for a sender', () {
        SenderSortChoices(store).choose(_broker.address, MessageCategory.codes);
        expect(SenderSortChoices(store).all, isEmpty);
        expect(classify(_broker, 'Account update').unsure, isTrue);
      });

      test('the newest choices are kept; a damaged setting is empty', () {
        final choices = SenderSortChoices(store);
        for (var i = 0; i < SenderSortChoices.keep + 2; i++) {
          choices.choose('s$i@shop.example', MessageCategory.newsletters);
        }
        expect(choices.all, hasLength(SenderSortChoices.keep));
        expect(choices.forSender('s0@shop.example'), isNull);
        expect(
          choices.forSender('s${SenderSortChoices.keep + 1}@shop.example'),
          MessageCategory.newsletters,
        );
        store.settings.write(SenderSortChoices.key, '[1, 2');
        expect(choices.all, isEmpty);
        choices.clear();
        expect(store.settings.read(SenderSortChoices.key), isNull);
      });
    });
  });
}
