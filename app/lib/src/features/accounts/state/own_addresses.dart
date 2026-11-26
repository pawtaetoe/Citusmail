// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

extension OwnAddresses on MailStore {
  /// Every address of the user's accounts.
  List<String> get ownAddresses => [for (final a in accounts.all()) a.email];
}
