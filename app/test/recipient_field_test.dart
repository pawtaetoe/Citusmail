// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/compose/compose_controller.dart';
import 'package:citusmail/src/compose/recipient_field.dart';
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
}
