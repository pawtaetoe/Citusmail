// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_setup/mail_setup.dart';

import '../../../app/app.dart' show appName;
import '../../../core/state/validation.dart';

/// What account setup is given, typed in the forms or sent from the
/// phone, checked the same way ([Validator]s from the toolkit).
abstract final class AccountFields {
  static const email = SetupEmail();
  static const host = HostName();
  static const port = Port();
  static const username = TextInput(
    empty: 'Enter your user name',
    maxLength: EmailAddress.maxLength,
  );

  /// "Your name (optional)", shown to people the user writes to.
  static const displayName = TextInput(maxLength: 200);
}

/// An email address account setup can look up, trimmed: one the mail
/// parser reads ([EmailAddress]) and the discovery can use
/// ([AccountDiscovery.supportsAddress]).
final class SetupEmail extends Validator<String> {
  const SetupEmail({this.reason = 'Enter an email address'});

  final String reason;

  @override
  Validated<String> call(String input) {
    final text = input.trim();
    if (EmailAddress(reason: reason, sendable: false)(text) case Invalid(
      :final reason,
    )) {
      return Invalid(reason);
    }
    if (!AccountDiscovery.supportsAddress(text)) {
      return const Invalid(
        '$appName can only set up addresses whose domain is written in '
        'plain letters, like name@example.com.',
      );
    }
    return Valid(text);
  }
}
