// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Search forgives typos: what was typed is matched exactly first, and
// when that finds little, terms are corrected to words of the user's
// mail (subjects and senders).

import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

void main() {
  late TempStore temp;
  late MailStore store;
  late StoredMailbox inbox;
  var uid = 0;

  setUp(() {
    temp = TempStore.create();
    store = temp.store;
    final account = temp.addAccount();
    inbox = store.mailboxes.replaceAll(account.id, [
      ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
    ]).single;
    uid = 0;
  });
  tearDown(() => temp.dispose());

  int add(String subject, {String? name, String address = 'a@x.example'}) {
    final at = address.indexOf('@');
    store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: ++uid,
        subject: subject,
        receivedAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: uid)),
        from: MailAddress(
          displayName: name,
          localPart: address.substring(0, at),
          domain: address.substring(at + 1),
        ),
      ),
    ]);
    return uid;
  }

  void body(int uid, String text) => store.messages.saveBody(
    store.messages.byUid(inbox.id, uid)!.id,
    Uint8List(0),
    searchableText: text,
  );

  List<int> uids(SearchResults r) => [for (final m in r.messages) m.uid];
  SearchResults find(String text) => store.messages.searchForgiving(text);

  group('typos find the message', () {
    late int parcel, delivery, invoice, munich, cart;
    setUp(() {
      parcel = add(
        'Please receive the parcel',
        name: 'Amazon',
        address: 'orders@amazon.com',
      );
      delivery = add(
        'Delivery update for your order',
        name: 'John Smith',
        address: 'john.smith@post.example',
      );
      invoice = add('Invoice for March', name: 'Accounts');
      munich = add('Café opening', name: 'Jürgen Müller');
      cart = add('Your cart is waiting', name: 'Shop');
    });

    test('two letters swapped', () {
      final r = find('recieve');
      expect(uids(r), [parcel]);
      expect(r.correctedText, 'receive');
      expect(r.exactCount, 0);
    });

    test('a letter missing, extra or wrong', () {
      expect(uids(find('recive')), [parcel]);
      expect(uids(find('receeive')), [parcel]);
      expect(uids(find('invoise')), [invoice]);
      expect(find('invoise').correctedText, 'invoice');
      expect(uids(find('delivry')), [delivery]);
    });

    test('two mistakes in a long word, one in a short word', () {
      expect(uids(find('dilivrei')), isEmpty, reason: 'three mistakes');
      expect(uids(find('dilivrey')), [delivery], reason: 'two mistakes');
      expect(uids(find('parcle')), [parcel]);
      expect(uids(find('parkle')), isEmpty, reason: 'two mistakes, 6 letters');
    });

    test('words typed together', () {
      final r = find('deliveryupdate');
      expect(uids(r), [delivery]);
      expect(r.correctedText, 'delivery update');
    });

    test('sender names and addresses', () {
      expect(uids(find('amzon')), [parcel]);
      expect(find('amzon').correctedText, 'amazon');
      expect(uids(find('jhon')), [delivery]);
      expect(uids(find('smtih')), [delivery]);
    });

    test('accents and case fold, as before', () {
      expect(uids(find('MULER')), [munich]);
      expect(uids(find('jurgen')), [munich], reason: 'exact');
      expect(find('jurgen').corrected, isFalse);
      expect(uids(find('Cafe')), [munich]);
      expect(uids(find('CAFFÉ')), [munich], reason: 'one extra, folded');
      expect(uids(find('cafféé')), isEmpty, reason: 'two extra, 6 letters');
    });

    test('only the term with a typo is corrected', () {
      final r = find('recieve parcel');
      expect(uids(r), [parcel]);
      expect(r.correctedText, 'receive parcel');
      expect(uids(find('recieve march')), isEmpty);
    });

    test('short terms stay exact', () {
      expect(uids(find('cart')), [cart]);
      expect(uids(find('cat')), isEmpty, reason: 'under 4 letters');
      expect(uids(find('crt')), isEmpty);
      expect(uids(find('jon')), isEmpty);
    });

    test('no matches for unrelated words', () {
      for (final word in [
        'zebra',
        'volcano',
        'piano',
        'umbrella',
        'xylophone',
        'quantum',
        'giraffe',
        'bicycle',
        'orange',
        'market',
      ]) {
        expect(uids(find(word)), isEmpty, reason: word);
      }
    });

    test('numbers and addresses are not corrected', () {
      add('Order 12345 shipped');
      expect(uids(find('12354')), isEmpty);
      expect(uids(find('jhon@post')), isEmpty);
    });
  });

  test('exact matches come first; corrections only when they are few', () {
    final typo = add('Did you get it?');
    body(typo, 'Did you recieve it?');
    final older = add('Please receive the parcel');
    final newer = add('We receive your order');
    body(older, 'nothing here');
    var r = find('recieve');
    expect(uids(r), [typo, newer, older]);
    expect(r.exactCount, 1);
    expect(r.correctedText, 'receive');
    expect(store.messages.search('recieve').map((m) => m.uid), [
      typo,
    ], reason: 'plain search stays exact');

    // Enough exact matches: nothing is corrected.
    for (var i = 0; i < 4; i++) {
      body(add('Number $i'), 'recieve');
    }
    r = find('recieve');
    expect(r.messages, hasLength(5));
    expect(r.corrected, isFalse);
    expect(r.messages.map((m) => m.uid), isNot(contains(older)));
  });

  test('a term found in bodies is no typo', () {
    for (var i = 0; i < 5; i++) {
      body(add('Note $i'), 'the kubernets cluster');
    }
    add('Kubernetes upgrade');
    final r = find('kubernets');
    expect(r.corrected, isFalse);
    expect(r.messages, hasLength(5));
  });

  test('Chinese and Japanese stay exact', () {
    final meeting = add('會議通知：明天上午十點');
    final japanese = add('会議のお知らせ');
    expect(uids(find('會議通知')), [meeting]);
    expect(uids(find('會議')), [meeting], reason: 'the short fallback');
    expect(uids(find('會議通報')), isEmpty);
    expect(uids(find('お知らせ')), [japanese]);
    expect(uids(find('お知らさ')), isEmpty);
    expect(store.searchWords.all().keys, isNot(contains('會議通知')));
  });

  test('mixed with a short term, through the fallback', () {
    final parcel = add('Please receive the parcel', name: 'Amazon');
    final r = find('recieve pa');
    expect(uids(r), [parcel]);
    expect(r.correctedText, 'receive pa');
  });

  group('words', () {
    test('counted as messages are stored, changed and removed', () {
      add(
        'Invoice of March 2026',
        name: 'Ana Müller',
        address: 'ana@shop.example',
      );
      add('Invoice for April', address: 'billing@shop.example');
      final words = store.searchWords;
      expect(words.count('invoice'), 2);
      expect(words.count('INVOICE'), 2, reason: 'folded');
      expect(words.count('müller'), 1);
      expect(words.count('muller'), 1);
      expect(words.count('shop'), 2, reason: 'from the address');
      expect(words.count('for'), 1);
      expect(words.count('ana'), 1);
      expect(words.all().keys, isNot(contains('of')), reason: 'too short');
      expect(words.all().keys, isNot(contains('2026')), reason: 'a number');

      // The subject changes on the server.
      store.messages.upsertSummaries(inbox.id, [
        MessageSummary(
          uid: 2,
          subject: 'Receipt for April',
          receivedAt: DateTime.utc(2026, 10, 1),
          from: const MailAddress(localPart: 'billing', domain: 'shop.example'),
        ),
      ]);
      expect(words.count('invoice'), 1);
      expect(words.count('receipt'), 1);
      expect(words.count('april'), 1);

      store.messages.removeUids(inbox.id, [1]);
      expect(words.count('invoice'), 0);
      expect(words.all().keys, isNot(contains('invoice')), reason: 'forgotten');
      expect(words.count('muller'), 0);
      expect(words.count('shop'), 1);
      expect(
        store.database
            .select('SELECT count(*) FROM search_word_trigrams')
            .first
            .columnAt(0),
        words.all().length,
        reason: 'no trigrams of forgotten words',
      );

      // Undo puts the words back.
      final id = store.messages.byUid(inbox.id, 2)!.id;
      final snapshot = store.messages.snapshot([id]);
      store.messages.removeUids(inbox.id, [2]);
      expect(words.all(), isEmpty);
      store.messages.restore(snapshot);
      expect(words.count('receipt'), 1);

      // A whole account going removes its words.
      store.accounts.remove(store.accounts.all().single.id);
      expect(words.all(), isEmpty);
    });

    test('a word is corrected to the most used close word', () {
      add('Relieve stress');
      for (var i = 0; i < 3; i++) {
        add('Receive $i');
      }
      expect(store.searchWords.correct('recieve')?.words, ['receive']);
      expect(store.searchWords.correct('receive'), isNull, reason: 'a word');
      expect(store.searchWords.correct('rec'), isNull, reason: 'too short');
    });
  });

  group('typing mistakes are counted', () {
    int d(String a, String b) => SearchWords.distance(a, b);
    test('like Damerau-Levenshtein, capped', () {
      expect(d('receive', 'receive'), 0);
      expect(d('recieve', 'receive'), 1);
      expect(d('recive', 'receive'), 1);
      expect(d('receeive', 'receive'), 1);
      expect(d('invoise', 'invoice'), 1);
      expect(d('jhon', 'john'), 1);
      expect(d('delivrey', 'delivery'), 1);
      expect(d('dilivrey', 'delivery'), 2);
      expect(d('abcdef', 'ghijkl'), 3, reason: 'stops above the cap');
      expect(SearchWords.distance('abc', 'abcdef', max: 1), 2);
    });

    test('folding and words', () {
      expect(
        SearchWords.fold('Müller ÉCOLE Ångström'),
        'muller ecole angstrom',
      );
      expect(SearchWords.of(['Re: Café', 'J. Müller', 'jm@shop.example']), {
        'cafe',
        'muller',
        'shop',
        'example',
      });
      expect(SearchWords.isCorrectable('recieve'), isTrue);
      expect(SearchWords.isCorrectable('cat'), isFalse);
      expect(SearchWords.isCorrectable('會議通知'), isFalse);
      expect(SearchWords.isCorrectable('a@b.cd'), isFalse);
      expect(SearchWords.isCorrectable('2026'), isFalse);
    });
  });
}
