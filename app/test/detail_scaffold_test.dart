// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/core/widgets/detail_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a detail page shows its title, header, facts, emails and '
      'actions, in that order', (tester) async {
    String? chose;
    var copied = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => DetailScaffold(
            title: 'Dentist',
            header: DetailHeader(
              leading: const CircleAvatar(child: Icon(Icons.event)),
              title: 'Check-up',
              subtitle: 'Tomorrow at 9:00',
              notes: const ['It was moved.'],
              facts: [
                const DetailFact(label: 'Where', value: 'High Street 1'),
                DetailFact(
                  label: 'Reference',
                  value: 'AB12',
                  onTap: () => copied++,
                  trailing: const Icon(Icons.copy),
                ),
                const DetailFact.wide(label: 'Booked with', value: ''),
              ],
              footer: const [Text('Times as written in the email.')],
            ),
            actions: [
              TextButton(
                onPressed: () => chose = 'not one',
                child: const Text('Not an appointment'),
              ),
            ],
            children: const [
              DetailSection(
                title: 'Emails',
                children: [
                  ListTile(title: Text('Booked')),
                  ListTile(title: Text('Moved')),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    for (final text in [
      'Dentist',
      'Check-up',
      'Tomorrow at 9:00',
      'It was moved.',
      'Where',
      'High Street 1',
      'Times as written in the email.',
      'Emails',
      'Booked',
      'Moved',
      'Not an appointment',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.text('Booked with'), findsNothing, reason: 'empty: hidden');
    expect(
      find.byType(Divider),
      findsNWidgets(2),
      reason:
          'under the title, '
          'and between the two emails',
    );

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Check-up'), lessThan(top('Where')));
    expect(top('Where'), lessThan(top('Emails')));
    expect(top('Booked'), lessThan(top('Moved')));
    expect(top('Moved'), lessThan(top('Not an appointment')));

    await tester.tap(find.text('AB12'));
    expect(copied, 1);
    await tester.tap(find.text('Not an appointment'));
    expect(chose, 'not one');
  });

  testWidgets('a section without a title is just the card', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(
          child: DetailSection(children: [ListTile(title: Text('Welcome'))]),
        ),
      ),
    );
    expect(find.byType(Card), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
    expect(find.text('Welcome'), findsOneWidget);
  });
}
