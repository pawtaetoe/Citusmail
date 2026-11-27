// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';

import '../../settings/state/setting_id.dart';

/// What a command in the command bar does, as a typed id. [id] is the
/// text kept in the recent commands ("go.inbox", "action.archive"); it
/// never changes once released, and [parse] reads it back.
sealed class CommandId {
  const CommandId();

  /// As kept in the recent commands.
  String get id;

  /// [id] as a command, or null for one this version doesn't know (from
  /// another version): it is left out.
  static CommandId? parse(String id) {
    final dot = id.indexOf('.');
    if (dot < 0) return id == 'search' ? const SearchCommand() : null;
    final kind = id.substring(0, dot), rest = id.substring(dot + 1);
    return switch (kind) {
      'action' => switch (_actions[rest]) {
        final action? => ActionCommand(action),
        null => null,
      },
      'go' => _place(rest),
      'setting' => switch (SettingId.parse(rest)) {
        final setting? => SettingCommand(setting),
        null => null,
      },
      'new' => switch (_creates[rest]) {
        final create? => CreateCommand(create),
        null => null,
      },
      'email' => switch (int.tryParse(rest)) {
        final messageId? => EmailCommand(MessageId(messageId)),
        null => null,
      },
      _ => null,
    };
  }

  static CommandId? _place(String rest) {
    if (_places[rest] case final place?) return PlaceCommand(place);
    final dot = rest.indexOf('.');
    if (dot < 0) return null;
    final kind = rest.substring(0, dot), value = rest.substring(dot + 1);
    return switch (kind) {
      'section' => switch (_sections[value]) {
        final section? => SectionCommand(section),
        null => null,
      },
      'account' => switch (int.tryParse(value)) {
        final accountId? => AccountCommand(AccountId(accountId)),
        null => null,
      },
      'folder' => switch (int.tryParse(value)) {
        final mailboxId? => FolderCommand(MailboxId(mailboxId)),
        null => null,
      },
      _ => null,
    };
  }

  static final _actions = CommandAction.values.asNameMap();
  static final _places = CommandPlace.values.asNameMap();
  static final _creates = CommandCreate.values.asNameMap();
  static final _sections = SmartSection.values.asNameMap();

  @override
  bool operator ==(Object other) => other is CommandId && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// An action on the open email or the selection.
enum CommandAction {
  archive,
  delete,
  move,
  snooze,
  pin,
  read,
  block,
  reply,
  replyAll,
  forward,
  summarise,
  translate,
}

/// A place to go that is always there.
enum CommandPlace {
  inbox,
  pins,
  snoozed,
  followUps,
  outbox,
  screener,
  subscriptions,
  deliveries,
  returns,
  trips,
  appointments,
  onlineAccounts,
  files,
  cleanUp,
  privacyReport,
  settings,
  features,
  shortcuts,
}

/// Something new to make.
enum CommandCreate { message, account }

/// `action.<name>`.
final class ActionCommand extends CommandId {
  const ActionCommand(this.action);

  final CommandAction action;

  @override
  String get id => 'action.${action.name}';
}

/// `go.<name>`.
final class PlaceCommand extends CommandId {
  const PlaceCommand(this.place);

  final CommandPlace place;

  @override
  String get id => 'go.${place.name}';
}

/// `go.section.<name>`: a section of the inbox.
final class SectionCommand extends CommandId {
  const SectionCommand(this.section);

  final SmartSection section;

  @override
  String get id => 'go.section.${section.name}';
}

/// `go.account.<id>`: one account's inbox.
final class AccountCommand extends CommandId {
  const AccountCommand(this.accountId);

  final AccountId accountId;

  @override
  String get id => 'go.account.${accountId.value}';
}

/// `go.folder.<id>`: a folder.
final class FolderCommand extends CommandId {
  const FolderCommand(this.mailboxId);

  final MailboxId mailboxId;

  @override
  String get id => 'go.folder.${mailboxId.value}';
}

/// `setting.<id>`: a setting, in Settings.
final class SettingCommand extends CommandId {
  const SettingCommand(this.setting);

  final SettingId setting;

  @override
  String get id => 'setting.${setting.id}';
}

/// `new.<name>`.
final class CreateCommand extends CommandId {
  const CreateCommand(this.create);

  final CommandCreate create;

  @override
  String get id => 'new.${create.name}';
}

/// `email.<id>`: an email found by the search (never kept as recent).
final class EmailCommand extends CommandId {
  const EmailCommand(this.messageId);

  final MessageId messageId;

  @override
  String get id => 'email.${messageId.value}';
}

/// `search`: a search of all mail (never kept as recent).
final class SearchCommand extends CommandId {
  const SearchCommand();

  @override
  String get id => 'search';
}
