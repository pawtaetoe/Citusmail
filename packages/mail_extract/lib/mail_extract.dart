// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Reads the schema.org data embedded in email HTML (JSON-LD and
/// microdata), on the device, without running anything: parcel
/// deliveries and orders, and reservations (flights, hotels, trains,
/// buses, rental cars, restaurant tables and event tickets), and
/// appointments (a dentist, a salon, a class). Each is a typed view of a
/// generic [SchemaThing].
library;

export 'src/appointments.dart';
export 'src/orders.dart';
export 'src/reservations.dart';
export 'src/schema_org.dart';
