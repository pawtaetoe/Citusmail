// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Moving mail accounts from the phone to a computer over the local
/// network (or as a sealed file), after scanning a QR code.
library;

export 'src/pairing_client.dart';
export 'src/pairing_crypto.dart';
export 'src/pairing_host.dart' hide PairingMessage;
export 'src/pairing_offer.dart';
export 'src/transfer.dart';
export 'src/x25519.dart';
