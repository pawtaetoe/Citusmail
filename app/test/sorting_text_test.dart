// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/src/home/sorting_text.dart';
import 'package:mail_store/mail_store.dart';

void main() {
  test('a move says whether it covers a sender or a whole list', () {
    expect(
      SortingText.moved(
        CategoryChoice(
          scope: ChoiceScope.sender,
          key: 'News@Shop.example',
          category: MessageCategory.people,
        ),
      ),
      'Mail from news@shop.example now goes to People.',
    );
    expect(
      SortingText.moved(
        CategoryChoice(
          scope: ChoiceScope.list,
          key: 'dev.lists.project.example',
          category: MessageCategory.notifications,
        ),
      ),
      'Mail from the list dev.lists.project.example now goes to Notifications.',
    );
  });

  test('every category has a name', () {
    expect(MessageCategory.values.map(SortingText.category), [
      'People',
      'Newsletters',
      'Notifications',
    ]);
  });
}
