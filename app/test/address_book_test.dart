// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Recipient suggestions while writing: read from the store once, then
// matched in memory, with the same results as asking the store.

import 'package:citusmail/src/compose/address_book.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;

  setUp(() async => app = await TestApp.create());
  tearDown(() => app.dispose());

  test('read once; the same suggestions as the store gives', () {
    var loads = 0;
    final book = AddressBook(() {
      loads++;
      return app.store.messages.suggestionCandidates();
    });
    for (final typed in ['a', 'ex', 'EXAMPLE', '.', 'li', '%', '_', 'zzz']) {
      expect(
        book.suggest(typed).map((a) => a.address),
        app.store.messages.suggestAddresses(typed).map((a) => a.address),
        reason: typed,
      );
    }
    expect(book.suggest('ex'), isNotEmpty);
    expect(book.suggest('  '), isEmpty);
    expect(loads, 1, reason: 'one read for every key press');
  });
}
