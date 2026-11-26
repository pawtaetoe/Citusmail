// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/features/found/state/found_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a found page splits what is listed from what is left out', () {
    final page = FoundPage<String, String>('findings', (
      all: ['a', 'b', 'c', 'd'],
      hidden: {'b'},
      learned: {'d'},
      toRead: [7],
    ), (item) => item);
    expect(page.listed, ['a', 'c']);
    expect(page.hiddenOnes, ['b', 'd']);
    expect(page.toRead, [7]);
    expect(page.found, 'findings');

    final changed = page.withFound('changed');
    expect(changed.found, 'changed');
    expect(changed.listed, ['a', 'c']);
    expect(changed.hidden, {'b'});
    expect(changed.learned, {'d'});
  });
}
