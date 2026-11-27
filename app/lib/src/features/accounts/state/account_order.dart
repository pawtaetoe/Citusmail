// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';

/// The order of the user's accounts, which the sidebar, the From choice
/// and new messages (from the top account) follow.
final class AccountOrder {
  AccountOrder(this._store);

  final MailStore _store;

  /// Changes when the accounts' order changes, so the sidebar follows.
  final changed = ValueNotifier<int>(0);

  /// Puts the accounts in the order of [ids].
  void reorder(List<int> ids) {
    _store.accounts.reorder(ids);
    changed.value++;
  }

  void dispose() => changed.dispose();
}
