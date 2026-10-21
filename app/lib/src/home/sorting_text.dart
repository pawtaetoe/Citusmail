// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

/// User-facing wording for sorting, in one place.
abstract final class SortingText {
  static String category(MessageCategory category) => switch (category) {
    MessageCategory.people => 'People',
    MessageCategory.newsletters => 'Newsletters',
    MessageCategory.notifications => 'Notifications',
  };

  static String moveTo(MessageCategory category) =>
      'Move to ${SortingText.category(category)}';

  static const decideAgain = 'Let Fmail sort these again';

  /// Confirms a move, saying what it covers.
  static String moved(CategoryChoice choice) => switch (choice.scope) {
    ChoiceScope.sender =>
      'Mail from ${choice.key} now goes to ${category(choice.category)}.',
    ChoiceScope.list =>
      'Mail from the list ${choice.key} now goes to ${category(choice.category)}.',
  };

  static String forgotten(CategoryChoice choice) => switch (choice.scope) {
    ChoiceScope.sender =>
      'Fmail sorts mail from ${choice.key} by itself again.',
    ChoiceScope.list =>
      'Fmail sorts mail from the list ${choice.key} by itself again.',
  };

  static const cannotMove =
      'This message has no sender or list to remember, so it can\'t be moved.';
}
