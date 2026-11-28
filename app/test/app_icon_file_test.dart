// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the icon SVG is recognised as SVG by Linux desktops', () {
    // shared-mime-info (and so GdkPixbuf and Flatpak's icon check) looks
    // for "<svg" in the first 256 bytes only; a long comment before it
    // makes the file "not a valid icon".
    final bytes = File('../assets/icon/icon.svg').readAsBytesSync();
    final head = String.fromCharCodes(bytes.take(256));
    expect(head, contains('<svg'));
  });
}
