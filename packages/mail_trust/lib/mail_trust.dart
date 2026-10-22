// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Local checks that warn about suspicious mail. Everything runs on the
/// device: no lookups, no reputation services, nothing sent anywhere.
library;

export 'src/attachments.dart';
export 'src/authentication_results.dart';
export 'src/brands.dart' show Brand, Brands;
export 'src/domains.dart';
export 'src/free_mail.dart';
export 'src/link_cleaner.dart';
export 'src/links.dart';
export 'src/trust_checker.dart';
export 'src/trust_report.dart';
