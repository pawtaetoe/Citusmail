// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/widgets/confirm_dialog.dart';
import 'package:citusmail/src/features/found/ui/found_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a confirm dialog says yes only when confirmed', (tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answers.add(
              await confirmDialog(
                context,
                title: 'Remove it?',
                message: 'Nothing is deleted on the server.',
                confirm: 'Remove',
              ),
            ),
            child: const Text('Ask'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(find.text('Remove it?'), findsOneWidget);
    expect(find.text('Nothing is deleted on the server.'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    await tester.tapAt(Offset.zero); // dismissed
    await tester.pumpAndSettle();
    expect(answers, [true, false, false]);
  });

  testWidgets('left-out items fold, say why, and list again', (tester) async {
    var open = false;
    final listedAgain = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Material(
            child: ListView(
              children: [
                LeftOutList(
                  marked: 'not a booking',
                  plural: 'bookings',
                  open: open,
                  onToggle: () => setState(() => open = !open),
                  items: [
                    for (final (name, learned) in [
                      ('Hotel', false),
                      ('Ferry', true),
                    ])
                      (
                        leading: const Icon(Icons.hotel),
                        title: name,
                        about: 'Your stay',
                        learned: learned,
                        onListAgain: () => listedAgain.add(name),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Show 2 marked "not a booking"'), findsOneWidget);
    expect(find.text('Hotel'), findsNothing);
    await tester.tap(find.text('Show 2 marked "not a booking"'));
    await tester.pump();
    expect(find.text('Hide the ones marked "not a booking"'), findsOneWidget);
    expect(find.text('Your stay'), findsOneWidget);
    expect(
      find.text('Left out: like ones you said aren\'t bookings'),
      findsOneWidget,
    );
    await tester.tap(find.text('List again').last);
    expect(listedAgain, ['Ferry']);
  });

  testWidgets('reading emails: the offer, then progress with Stop', (
    tester,
  ) async {
    var read = 0;
    var stopped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Column(
            children: [
              ReadEmailsOffer(
                icon: Icons.receipt,
                text: '3 receipts are not on this device yet.',
                button: 'Read receipts',
                onRead: () => read++,
              ),
              ReadingEmails(
                what: 'receipts',
                done: 1,
                total: 3,
                onStop: () => stopped++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Read receipts'));
    expect(find.text('Reading receipts: 1 of 3'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    expect((read, stopped), (1, 1));
  });
}
