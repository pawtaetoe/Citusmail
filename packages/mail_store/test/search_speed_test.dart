// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Speed of forgiving search on a large mailbox of generated mail, and
// what keeping the search words costs when mail is stored.

// Timings are printed for the record.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

/// Generated mail: common words, names and companies, and many rarer
/// made-up words, so there are tens of thousands of distinct words.
final class GeneratedMail {
  GeneratedMail(int seed) : _random = Random(seed);

  final Random _random;

  static final common =
      ('your order invoice receive delivery update meeting project report '
              'account payment receipt welcome reminder weekly newsletter '
              'schedule shipping confirmed password security request review '
              'question holiday flight booking ticket dinner tomorrow monday '
              'friday notes budget contract quarterly results team office '
              'parcel tracking statement subscription renewal offer discount '
              'photos family birthday party agenda minutes draft proposal '
              'feedback interview application support issue release version '
              'launch summer winter school')
          .split(' ');
  static final first =
      ('John Mary Ahmed Sofia Lukas Chen Priya Olga Pierre Fatima Kenji '
              'Maria David Anna Jürgen Zoë Mateo Emma Noah Ingrid Rahul Ewa '
              'Tomás Leila')
          .split(' ');
  static final last =
      ('Smith Müller Garcia Nowak Rossi Dubois Kowalski Johansson Silva '
              'Novak Haddad Tanaka Okafor Murphy Jensen Kim Patel Ivanova '
              'Costa Fischer Brown Lopez')
          .split(' ');
  static final companies =
      ('amazon paypal github airbnb spotify netflix dropbox linkedin '
              'zalando ikea lufthansa deutschebahn')
          .split(' ');
  static final _syllables =
      ('ka lo mi ren tas vo quin bel dor fi gan hu jel kor lin mar nes op '
              'pra ris sul tem ur vel wix yan zor bri cla dre esk fon')
          .split(' ');

  T _pick<T>(List<T> list) => list[_random.nextInt(list.length)];

  /// Common words are picked far more often than the first ones of a long
  /// tail (roughly like real text).
  String word() {
    if (_random.nextDouble() < 0.6) {
      final i = (pow(_random.nextDouble(), 2) * common.length).floor();
      return common[i];
    }
    final n = 2 + _random.nextInt(3);
    return [for (var i = 0; i < n; i++) _pick(_syllables)].join();
  }

  String words(int least, int most) => [
    for (var i = 0, n = least + _random.nextInt(most - least); i < n; i++)
      word(),
  ].join(' ');

  MailAddress sender() {
    if (_random.nextDouble() < 0.3) {
      final company = _pick(companies);
      return MailAddress(
        displayName: company[0].toUpperCase() + company.substring(1),
        localPart: _pick(['noreply', 'orders', 'info', 'news']),
        domain: '$company.example',
      );
    }
    final f = _pick(first), l = _pick(last);
    return MailAddress(
      displayName: '$f $l',
      localPart: '${f.toLowerCase()}.${word()}',
      domain: '${word()}.example',
    );
  }

  List<MessageSummary> summaries(int fromUid, int count) => [
    for (var uid = fromUid; uid < fromUid + count; uid++)
      MessageSummary(
        uid: uid,
        subject: words(3, 9),
        from: sender(),
        receivedAt: DateTime.utc(2020).add(Duration(minutes: uid * 7)),
        snippet: 'snippet',
      ),
  ];
}

/// Milliseconds of processor time this process used: steadier than the
/// clock on a busy machine. The clock where it can't be read.
int processorMs() {
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    // utime and stime, in ticks of (nearly always) 10 ms.
    return (int.parse(fields[11]) + int.parse(fields[12])) * 10;
  } on Object {
    return _clock.elapsedMilliseconds;
  }
}

final _clock = Stopwatch()..start();

void main() {
  late TempStore temp;
  setUp(() => temp = TempStore.create());
  tearDown(() => temp.dispose());

  MailboxId inbox(MailStore store) {
    final account = store.accounts.all().firstOrNull ?? temp.addAccount();
    return store.mailboxes
        .replaceAll(account.id, [
          ImapMailboxInfo(encodedName: 'INBOX', delimiter: '/', attributes: {}),
        ])
        .single
        .id;
  }

  test('a corrected search of 50,000 messages takes under 150 ms', () {
    final store = temp.store;
    final mailbox = inbox(store);
    final mail = GeneratedMail(1);
    final setup = Stopwatch()..start();
    for (var uid = 1; uid <= 50000; uid += 500) {
      store.messages.upsertSummaries(mailbox, mail.summaries(uid, 500));
    }
    // Some bodies are downloaded too.
    store.transaction(() {
      for (var uid = 1; uid <= 50000; uid += 20) {
        store.messages.saveBody(
          store.messages.byUid(mailbox, uid)!.id,
          Uint8List(0),
          searchableText: mail.words(40, 120),
        );
      }
    });
    print(
      'stored 50,000 messages: ${setup.elapsedMilliseconds} ms, '
      '${store.searchWords.all().length} distinct words',
    );

    final typos = {
      'recieve': 'receive',
      'invoise': 'invoice',
      'amzon': 'amazon',
      'jhon': 'john',
      'quartrely': 'quarterly',
      'deliveryupdate': 'delivery update',
      'mueller': 'muller',
      'invoice shiping': 'invoice shipping',
    };
    // Once, so pages are read in, as in a running app.
    for (final typo in typos.keys) {
      store.messages.searchForgiving(typo, limit: 200);
    }
    final median = <String, int>{};
    for (final MapEntry(key: typo, value: meant) in typos.entries) {
      final times = <int>[];
      late SearchResults found;
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        found = store.messages.searchForgiving(typo, limit: 200);
        times.add(watch.elapsedMicroseconds);
      }
      median[typo] = (times..sort())[2];
      expect(found.correctedText, meant, reason: typo);
      expect(found.messages, isNotEmpty, reason: typo);
    }
    final shown = [
      for (final MapEntry(key: typo, value: us) in median.entries)
        '$typo ${(us / 1000).toStringAsFixed(1)}',
    ];
    print('corrected search, median of 5 (ms): ${shown.join(', ')}');
    for (final MapEntry(key: typo, value: us) in median.entries) {
      expect(us, lessThan(150000), reason: typo);
    }

    // A typo nothing is close to costs no more.
    final watch = Stopwatch()..start();
    expect(store.messages.searchForgiving('xqzvwk').messages, isEmpty);
    print('nothing close: ${watch.elapsedMicroseconds / 1000} ms');
    expect(watch.elapsedMilliseconds, lessThan(150));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('keeping the search words adds little to storing 5,000 messages', () {
    // Without the trigger that lists new mail for counting: storing as
    // before the search words.
    int time({required bool words}) {
      final store = temp.store;
      if (!words) store.database.execute('DROP TRIGGER messages_words_insert');
      final mailbox = inbox(store);
      final batches = [
        for (var uid = 1; uid <= 5000; uid += 100)
          GeneratedMail(uid).summaries(uid, 100),
      ];
      final start = processorMs();
      // As sync stores mail: 100 at a time.
      for (final batch in batches) {
        store.messages.upsertSummaries(mailbox, batch);
      }
      return processorMs() - start;
    }

    // The best of several runs, taken in turns, as other work on the
    // machine makes single runs vary.
    var before = 1 << 30, after = 1 << 30;
    for (var i = 0; i < 4; i++) {
      for (final words in [false, true]) {
        temp.dispose();
        temp = TempStore.create();
        final ms = time(words: words);
        if (words) {
          after = min(after, ms);
          expect(temp.store.searchWords.count('invoice'), greaterThan(0));
        } else {
          before = min(before, ms);
        }
      }
    }
    print(
      'storing 5,000 messages: $before ms without the search words, '
      '$after ms with them (processor time)',
    );
    expect(after, lessThan(before * 1.3 + 100));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
