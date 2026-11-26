// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/features/compose/state/compose_controller.dart';
import 'package:citusmail/src/features/compose/ui/recipient_field.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';

void main() {
  const tommy = MailAddress(
    localPart: 'tommykung4',
    domain: 'gmail.com',
    displayName: 'Tommy Kung',
  );

  var looked = <String>[];

  Future<RecipientList> show(WidgetTester tester) async {
    looked = [];
    final list = RecipientList(const []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RecipientField(
                label: 'To',
                list: list,
                autofocus: true,
                suggest: (text) {
                  looked.add(text);
                  return [
                    if ('tommy kung tommykung4@gmail.com'.contains(
                      text.toLowerCase(),
                    ))
                      tommy,
                  ];
                },
              ),
              const TextField(),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return list;
  }

  testWidgets(
    'picking a suggestion adds it',
    (tester) async {
      final platform = defaultTargetPlatform;
      final list = await show(tester);
      await tester.enterText(find.byType(TextField).first, 'tom');
      await tester.pump(RecipientField.pause);
      await tester.pump();
      expect(find.text('Tommy Kung'), findsOneWidget);

      final gesture = await tester.createGesture(
        kind: platform == TargetPlatform.linux
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      await gesture.down(tester.getCenter(find.text('Tommy Kung')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(list.addresses, [tommy]);
      expect(list.invalid, isNull, reason: 'no "Not an email address"');
      expect(find.text('Not an email address'), findsNothing);
    },
    variant: TargetPlatformVariant(const {
      TargetPlatform.android,
      TargetPlatform.linux,
      TargetPlatform.windows,
    }),
  );

  testWidgets('suggestions are looked up once typing pauses', (tester) async {
    await show(tester);
    final field = find.byType(TextField).first;
    for (final typed in ['to', 'tom', 'tomm', 'tommy']) {
      await tester.enterText(field, typed);
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(looked, isEmpty, reason: 'nothing while typing');
    await tester.pump(RecipientField.pause);
    await tester.pump();
    expect(looked, ['tommy']);
    expect(find.text('Tommy Kung'), findsOneWidget);
  });

  group('pasted lists', () {
    List<String>? commit(String text) {
      final list = RecipientList(const [])..pending = text;
      return list.commit() ? [for (final a in list.addresses) '$a'] : null;
    }

    test('separated by semicolons, as Outlook copies them', () {
      expect(commit('j@x.example; a@y.example'), [
        'j@x.example',
        'a@y.example',
      ]);
      expect(commit('Doe, John <j@x.example>; Smith, Ann <a@y.example>;'), [
        'Doe, John <j@x.example>',
        'Smith, Ann <a@y.example>',
      ]);
      expect(commit('"Doe, John" <j@x.example>, ann@y.example'), [
        'Doe, John <j@x.example>',
        'ann@y.example',
      ]);
    });

    test('text that is not a list of addresses is refused', () {
      expect(commit('j@x.example a@y.example'), isNull);
      expect(commit('John Doe'), isNull);
    });

    test('IDN domains are kept; addresses mail can\'t go to say why', () {
      expect(commit('Jürgen <j@münchen.de>'), ['Jürgen <j@münchen.de>']);
      final list = RecipientList(const [])..pending = 'jürgen@example.com';
      expect(list.commit(), isFalse);
      expect(list.problem, contains('before the @'));
      expect(list.invalid, 'jürgen@example.com');
      // One of several: which one is named.
      list.pending = 'a@x.example, jürgen@example.com';
      expect(list.commit(), isFalse);
      expect(list.problem, startsWith('jürgen@example.com: '));
      expect(list.addresses, isEmpty, reason: 'nothing added from the list');
      list.pending = 'a@x.example';
      expect(list.problem, isNull, reason: 'typing clears it');
    });

    test('a pasted list is bounded', () {
      final many = [for (var i = 0; i <= 500; i++) 'p$i@x.example'].join(', ');
      final list = RecipientList(const [])..pending = many;
      expect(list.commit(), isFalse);
      expect(list.problem, 'At most 500 addresses in one field.');
      list.pending = 'a@x.example, ' * 10000;
      expect(list.commit(), isFalse);
      expect(list.problem, 'That is more text than a list of addresses.');
      expect(list.addresses, isEmpty);
    });
  });

  testWidgets('the reason shows under the field', (tester) async {
    final list = await show(tester);
    await tester.enterText(find.byType(TextField).first, 'jürgen@example.com,');
    await tester.pump();
    expect(list.addresses, isEmpty);
    expect(find.textContaining('before the @'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'nope,');
    await tester.pump();
    expect(find.text('Not an email address'), findsOneWidget);
    await tester.pump(RecipientField.pause);
  });
}
