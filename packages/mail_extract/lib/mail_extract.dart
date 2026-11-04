// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Reads the schema.org data embedded in email HTML (JSON-LD and
/// microdata), on the device, without running anything: parcel
/// deliveries and orders. [SchemaThing] holds any type, so reservations
/// (flights, hotels, events, trains, rental cars, restaurants) can get
/// their own typed views the same way.
library;

export 'src/orders.dart';
export 'src/schema_org.dart';
