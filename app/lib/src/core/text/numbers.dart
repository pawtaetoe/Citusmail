// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A count as the app shows it, with thousands separators: 1234 as
/// "1,234".
String grouped(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// "1 email", "7,080 emails": [n] of [one] (plural [many], else [one]
/// with an s).
String countOf(int n, String one, [String? many]) =>
    n == 1 ? '1 $one' : '${grouped(n)} ${many ?? '${one}s'}';
