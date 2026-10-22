// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// HTTPS requests to servers named inside mail, hardened for privacy and
/// safety. Nothing else in the app talks HTTP to such servers.
library;

export 'src/address_policy.dart';
export 'src/web_client.dart';
