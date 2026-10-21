// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

/// A "Move to" that was done, with what it replaced, so it can be reverted
/// exactly (e.g. from an Undo button).
final class CategoryMove {
  const CategoryMove(this.choice, this.replaced);

  final CategoryChoice choice;

  /// The earlier choice for the same list or sender, if there was one.
  final CategoryChoice? replaced;
}

/// "Move to People / Newsletters / Notifications", which also teaches the
/// sorter: the choice is remembered for the message's mailing list (so it
/// covers every poster) or, for other mail, its sender. Earlier and later
/// messages follow it until it is undone.
final class CategoryCorrections {
  CategoryCorrections(this._store);

  final MailStore _store;

  /// What a move of [message] would be remembered for: its list if it has
  /// one, else its sender. Null if it has neither.
  static (ChoiceScope, String)? targetOf(StoredMessage message) {
    if (message.listId case final listId?) return (ChoiceScope.list, listId);
    final sender = _senderKey(message);
    return sender == null ? null : (ChoiceScope.sender, sender);
  }

  /// Moves [message] (and everything else from its list or sender) to
  /// [category]. Returns what was done, or null if the message has no list
  /// or sender to remember.
  CategoryMove? move(StoredMessage message, MessageCategory category) {
    final target = targetOf(message);
    if (target == null) return null;
    final (scope, key) = target;
    final choice = CategoryChoice(scope: scope, key: key, category: category);
    return _store.transaction(() {
      final replaced = _store.categoryChoices.find(scope, key);
      _store.categoryChoices.save(choice);
      return CategoryMove(choice, replaced);
    });
  }

  /// Puts back what [move] replaced.
  void revert(CategoryMove move) => _store.transaction(() {
    final previous = move.replaced;
    if (previous != null) {
      _store.categoryChoices.save(previous);
    } else {
      _store.categoryChoices.remove(move.choice.scope, move.choice.key);
    }
  });

  /// The choice that decides [message]'s category, if any (a list choice
  /// wins over a sender choice, as in the store).
  CategoryChoice? choiceFor(StoredMessage message) {
    if (message.listId case final listId?) {
      final listChoice = _store.categoryChoices.find(ChoiceScope.list, listId);
      if (listChoice != null) return listChoice;
    }
    final sender = _senderKey(message);
    return sender == null
        ? null
        : _store.categoryChoices.find(ChoiceScope.sender, sender);
  }

  /// Forgets the choice deciding [message]'s category, so the rules (or
  /// the sender choice, after a list choice is removed) decide again.
  /// Returns what was removed.
  CategoryChoice? undo(StoredMessage message) {
    final choice = choiceFor(message);
    if (choice != null) {
      _store.categoryChoices.remove(choice.scope, choice.key);
    }
    return choice;
  }

  /// Forgets a choice from a settings list.
  bool forget(CategoryChoice choice) =>
      _store.categoryChoices.remove(choice.scope, choice.key);

  /// The sender address as a choice key, or null if it can't be one.
  static String? _senderKey(StoredMessage message) {
    final address = message.from?.address.trim();
    if (address == null || address.isEmpty) return null;
    if (address.length > CategoryChoice.maxKeyLength) return null;
    return address;
  }
}
