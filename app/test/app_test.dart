// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_test/flutter_test.dart';
import 'package:fmail/main.dart';

void main() {
  testWidgets('app starts', (tester) async {
    await tester.pumpWidget(const MailApp());
    expect(find.textContaining('under construction'), findsOneWidget);
  });
}
