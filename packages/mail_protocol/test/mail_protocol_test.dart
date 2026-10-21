// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('library loads', () {
    expect(mailProtocolVersion, isNotEmpty);
  });
}
