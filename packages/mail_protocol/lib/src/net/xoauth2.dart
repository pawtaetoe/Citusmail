// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// The SASL XOAUTH2 mechanism used by Outlook and Gmail for IMAP and SMTP.
abstract final class XOAuth2 {
  /// The client's first (and only) message, base64:
  /// `user=<name>^Aauth=Bearer <token>^A^A`.
  static String initialResponse(String username, String accessToken) {
    final bad = RegExp(r'[\x00-\x1F\x7F\s]');
    if (username.isEmpty || username.contains(bad)) {
      throw ArgumentError.value(username, 'username', 'not usable');
    }
    if (accessToken.isEmpty || accessToken.contains(bad)) {
      throw ArgumentError('the access token is not usable');
    }
    return base64.encode(
      utf8.encode('user=$username\u0001auth=Bearer $accessToken\u0001\u0001'),
    );
  }
}
