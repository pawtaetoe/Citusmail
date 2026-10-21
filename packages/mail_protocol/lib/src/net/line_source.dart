// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

/// Where protocol readers get bytes: whole lines and fixed-length runs.
/// [MailSocket] implements this; tests use in-memory sources.
abstract interface class LineSource {
  /// One line without its line ending.
  Future<Uint8List> readLine({Duration timeout});

  /// Exactly [length] bytes.
  Future<Uint8List> readBytes(int length, {Duration timeout});
}
