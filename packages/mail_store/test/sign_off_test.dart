// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

import 'support/temp_store.dart';

void main() {
  late TempStore temp;
  SignOffRepository signOffs() => temp.store.signOffs;

  setUp(() => temp = TempStore.create());
  tearDown(() => temp.dispose());

  test('starts with none', () {
    expect(signOffs().all(), isEmpty);
    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: false),
      isNull,
    );
  });

  test('adds, edits and removes sign-offs, in order', () {
    final work = signOffs().add(
      name: 'Work',
      text: 'Best regards,\nTommy Kung\nFluminaris\n\n',
    );
    final casual = signOffs().add(name: ' Casual ', text: 'Cheers,\nTommy');
    expect(signOffs().all().map((s) => s.name), ['Work', 'Casual']);
    expect(work.text, 'Best regards,\nTommy Kung\nFluminaris');
    expect(work.id, isNot(casual.id));

    signOffs().update(work.copyWith(text: 'Kind regards,\nTommy'));
    expect(signOffs().byId(work.id)!.text, 'Kind regards,\nTommy');
    expect(signOffs().all().first.name, 'Work', reason: 'keeps its place');

    signOffs().reorder([casual.id, work.id]);
    expect(signOffs().all().map((s) => s.name), ['Casual', 'Work']);

    signOffs().remove(casual.id);
    expect(signOffs().all().map((s) => s.name), ['Work']);
    // Other devices learn about the removal.
    expect(temp.store.appDataSync.tombstones().map((t) => (t.key, t.kind)), [
      (AppDataKeys.signOff(casual.id), 'signOff'),
    ]);
  });

  test('the block starts with "-- " only when asked', () {
    final plain = SignOff.oneOff(text: 'Cheers,\nTommy\n');
    expect(plain.block, 'Cheers,\nTommy');
    expect(plain.isSaved, isFalse);
    final standard = SignOff.oneOff(text: 'Tommy', separator: true);
    expect(standard.block, '-- \nTommy');
  });

  test('each account has its own defaults, for new mail and replies', () {
    final work = signOffs().add(name: 'Work', text: 'Best regards,\nTommy');
    final short = signOffs().add(name: 'Short', text: '– T');
    signOffs().setDefaults(
      'Tommy@Fluminaris.example',
      SignOffDefaults(
        newMail: work.id,
        repliesSameAsNew: false,
        replies: short.id,
        changedAt: DateTime.utc(2026, 11, 10),
      ),
    );
    signOffs().setDefaults(
      'tommy@home.example',
      SignOffDefaults(newMail: short.id, changedAt: DateTime.utc(2026, 11, 10)),
    );

    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: false),
      work,
    );
    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: true),
      short,
    );
    // Same for replies.
    expect(signOffs().defaultFor('tommy@home.example', reply: true), short);
    expect(signOffs().defaultFor('other@x.example', reply: false), isNull);

    // A removed sign-off is no longer anyone's default.
    signOffs().remove(short.id);
    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: true),
      isNull,
    );
    expect(signOffs().defaultFor('tommy@home.example', reply: false), isNull);
  });

  test('"none" for replies differs from "same as new mail"', () {
    final work = signOffs().add(name: 'Work', text: 'Best regards');
    signOffs().setDefaults(
      'tommy@fluminaris.example',
      SignOffDefaults(
        newMail: work.id,
        repliesSameAsNew: false,
        changedAt: DateTime.utc(2026),
      ),
    );
    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: true),
      isNull,
    );
    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: false),
      work,
    );
  });

  test('survives closing and opening the store', () {
    final work = signOffs().add(
      name: 'Work',
      text: 'Best regards,\nTommy Kung\nFluminaris',
      separator: true,
    );
    signOffs().setDefaults(
      'tommy@fluminaris.example',
      SignOffDefaults(newMail: work.id, changedAt: DateTime.utc(2026)),
    );
    temp.reopen();
    final again = signOffs().all().single;
    expect(again, work);
    expect(again.separator, isTrue);
    expect(
      signOffs().defaultFor('tommy@fluminaris.example', reply: true),
      work,
    );
  });

  test('damaged stored data reads as none instead of failing', () {
    temp.store.settings.write('signOffs', '{not json');
    expect(signOffs().all(), isEmpty);
    signOffs().add(name: 'Work', text: 'Best');
    expect(signOffs().all(), hasLength(1));
  });
}
