// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'mail_actions.dart';

/// How old a verification code gets before it is cleaned up.
enum CodeCleanupAge {
  off('off', null),
  day('day', Duration(days: 1)),
  week('week', Duration(days: 7));

  const CodeCleanupAge(this.storageName, this.age);

  final String storageName;

  /// Null when clean-up is off.
  final Duration? age;
}

/// Where cleaned-up codes go.
enum CodeCleanupAction {
  archive('archive'),
  trash('trash');

  const CodeCleanupAction(this.storageName);

  final String storageName;
}

/// Whether the user agreed to automatic clean-up. It moves mail on the
/// server, so nothing moves until they do.
sealed class CodeCleanupConsent {
  const CodeCleanupConsent();
}

/// Not asked yet.
final class ConsentUnasked extends CodeCleanupConsent {
  const ConsentUnasked();
}

final class ConsentGiven extends CodeCleanupConsent {
  const ConsentGiven();
}

/// "Not now", at [at]; asked again after [CodeCleaner.askAgainAfter].
final class ConsentDeclined extends CodeCleanupConsent {
  const ConsentDeclined(this.at);

  final DateTime at;
}

/// The clean-up choices, in the key-value settings (so the background job
/// reads the same values).
final class CodeCleanupSettings {
  CodeCleanupSettings(this._store);

  final MailStore _store;

  // Age, action and consent sync between devices as one preference: their
  // keys come from SyncedPreferences, which lists what syncs.

  /// After a day, unless the user chose otherwise.
  static const ageSetting = EnumSetting(
    SyncedPreferences.codeCleanupAge,
    CodeCleanupAge.values,
    fallback: CodeCleanupAge.day,
    storedAs: _ageName,
  );

  /// Archive, unless the user chose Trash.
  static const actionSetting = EnumSetting(
    SyncedPreferences.codeCleanupAction,
    CodeCleanupAction.values,
    fallback: CodeCleanupAction.archive,
    storedAs: _actionName,
  );

  static const consentSetting = CodeCleanupConsentSetting(
    SyncedPreferences.codeCleanupConsent,
  );

  /// When clean-up last ran here (the hourly turn).
  static const lastRunSetting = DateTimeSetting('codes.cleanup.lastRun');

  /// Messages the user brought back with Undo, one per line.
  static const undoneSetting = StringListSetting(
    'codes.cleanup.undone',
    separator: '\n',
  );

  static String _ageName(CodeCleanupAge age) => age.storageName;
  static String _actionName(CodeCleanupAction action) => action.storageName;

  CodeCleanupAge get age => ageSetting.read(_store.settings);

  set age(CodeCleanupAge age) => ageSetting.write(_store.settings, age);

  CodeCleanupAction get action => actionSetting.read(_store.settings);

  set action(CodeCleanupAction action) =>
      actionSetting.write(_store.settings, action);

  CodeCleanupConsent get consent => consentSetting.read(_store.settings);

  bool get agreed => consent is ConsentGiven;

  /// The user said yes; the next run is not held back by the hourly limit.
  void agree() => _store.transaction(() {
    consentSetting.write(_store.settings, const ConsentGiven());
    lastRunSetting.clear(_store.settings);
  });

  /// "Not now".
  void decline(DateTime now) =>
      consentSetting.write(_store.settings, ConsentDeclined(now));

  /// Messages the user brought back with Undo: never cleaned up again.
  Set<String> get undone => undoneSetting.read(_store.settings).toSet();

  void remember(Iterable<String> keys) {
    final all = [
      ...undoneSetting.read(_store.settings),
      ...keys,
    ].where((k) => k.isNotEmpty).toSet().toList();
    final kept = all.length > CodeCleaner.maxRemembered
        ? all.sublist(all.length - CodeCleaner.maxRemembered)
        : all;
    undoneSetting.write(_store.settings, kept);
  }
}

/// [CodeCleanupConsent] as stored: `yes`, or `no:` and when (milliseconds
/// since 1970). Anything else, or nothing, is [ConsentUnasked].
final class CodeCleanupConsentSetting extends Setting<CodeCleanupConsent> {
  const CodeCleanupConsentSetting(super.key)
    : super(fallback: const ConsentUnasked());

  @override
  CodeCleanupConsent? tryDecode(String stored) {
    if (stored == 'yes') return const ConsentGiven();
    if (stored.startsWith('no:')) {
      if (int.tryParse(stored.substring(3)) case final at?) {
        return ConsentDeclined(
          DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
        );
      }
    }
    return null;
  }

  @override
  String encode(CodeCleanupConsent value) => switch (value) {
    ConsentGiven() => 'yes',
    ConsentDeclined(:final at) => 'no:${at.millisecondsSinceEpoch}',
    ConsentUnasked() => '', // reads as unasked
  };
}

/// One clean-up: what moved, and how to undo it ([CodeCleaner.undo]).
final class CodeCleanup {
  const CodeCleanup._(this.messages, this.receipts, this.action);

  /// The messages as they were in the inbox.
  final List<StoredMessage> messages;
  final List<RemovalReceipt> receipts;
  final CodeCleanupAction action;

  int get count => messages.length;

  /// Accounts with queued moves (to sync them).
  Set<int> get accountIds => {for (final r in receipts) ...r.accountIds};
}

/// Moves old verification codes, sign-in links and password-reset emails
/// out of the inbox once they are useless.
///
/// Only messages in an inbox's Verification section, received before the
/// cut-off, and not pinned, a draft, replied to, or brought back with Undo
/// before. Mail in other folders is never touched. Moves go through
/// [MailActions], so they are local first, queued for the server, and work
/// offline. Runs at most once an hour, [batchSize] messages at a time, and
/// only after the user agreed ([CodeCleanupSettings.agree]).
final class CodeCleaner {
  CodeCleaner(this._store, this._actions)
    : settings = CodeCleanupSettings(_store);

  final MailStore _store;
  final MailActions _actions;
  final CodeCleanupSettings settings;

  static const interval = Duration(hours: 1);

  /// After "Not now", how long before asking again.
  static const askAgainAfter = Duration(days: 30);

  /// At most this many messages move in one run.
  static const batchSize = 200;

  /// Undone messages remembered (the oldest are forgotten first).
  static const maxRemembered = 1000;

  /// Whether to ask the user now: clean-up is on (as by default), they
  /// haven't agreed, didn't say "Not now" recently, and there is something
  /// it would move.
  bool shouldAsk(DateTime now) {
    if (settings.age == CodeCleanupAge.off) return false;
    switch (settings.consent) {
      case ConsentGiven():
        return false;
      case ConsentDeclined(:final at) when now.difference(at) < askAgainAfter:
        return false;
      case _:
        return candidates(now, limit: 1).isNotEmpty;
    }
  }

  /// The messages a run at [now] would move, oldest first. [except]: ids
  /// left alone this time (the message the user is reading).
  List<StoredMessage> candidates(
    DateTime now, {
    int limit = batchSize,
    Set<int> except = const {},
  }) {
    final age = settings.age.age;
    if (age == null) return const [];
    final cutoff = now.subtract(age);
    final undone = settings.undone;
    final found = <StoredMessage>[];
    for (final account in _store.accounts.all()) {
      if (_target(account.id) == null) continue;
      var query = MessageQuery.smart(
        SmartSection.codes,
        accountIds: [account.id],
        limit: 200,
      );
      while (found.length < limit) {
        final page = _store.messages.list(query);
        for (final m in page) {
          if (m.receivedAt.isBefore(cutoff) &&
              m.section == SmartSection.codes &&
              m.category == MessageCategory.codes &&
              !m.flags.flagged &&
              !m.flags.draft &&
              !m.flags.answered &&
              !m.flags.deleted &&
              !except.contains(m.id) &&
              !undone.contains(keyOf(m))) {
            found.add(m);
            if (found.length >= limit) break;
          }
        }
        if (page.length < query.limit) break;
        query = query.after(page.last);
      }
      if (found.length >= limit) break;
    }
    found.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    return found;
  }

  /// Cleans up, if it is on, agreed to, and the last run was over an hour
  /// ago. Null when nothing moved. [except]: ids left alone this time.
  CodeCleanup? run(DateTime now, {Set<int> except = const {}}) {
    if (settings.age == CodeCleanupAge.off || !settings.agreed) return null;
    if (!_claim(now)) return null;
    final messages = candidates(now, except: except);
    if (messages.isEmpty) return null;
    final byAccount = <int, List<StoredMessage>>{};
    for (final m in messages) {
      byAccount.putIfAbsent(m.accountId, () => []).add(m);
    }
    final receipts = <RemovalReceipt>[];
    final moved = <StoredMessage>[];
    for (final MapEntry(key: accountId, value: group) in byAccount.entries) {
      final target = _target(accountId);
      if (target == null) continue;
      receipts.add(_actions.move(group, target));
      moved.addAll(group);
    }
    if (moved.isEmpty) return null;
    return CodeCleanup._(moved, receipts, settings.action);
  }

  /// Puts a clean-up back, and keeps those messages out of later runs.
  /// False when it is too late (the move reached the server).
  bool undo(CodeCleanup cleanup) {
    settings.remember(cleanup.messages.map(keyOf));
    var all = true;
    for (final receipt in cleanup.receipts) {
      if (!_actions.undo(receipt)) all = false;
    }
    return all;
  }

  /// What identifies a message across Undo (which may give it a new id).
  static String keyOf(StoredMessage m) =>
      m.messageId ?? 'uid:${m.mailboxId}:${m.uid}';

  /// Where the account's codes go: its Archive (on Gmail, All Mail: the
  /// message just leaves the inbox), or its Trash. Null when there is
  /// none; then nothing is moved (a delete without a Trash would remove
  /// mail for good).
  StoredMailbox? _target(int accountId) => switch (settings.action) {
    CodeCleanupAction.archive => MailActions.archiveFolder(_store, accountId),
    CodeCleanupAction.trash => _store.mailboxes.bySpecialUse(
      accountId,
      SpecialUse.trash,
    ),
  };

  /// Takes the hourly turn, so the app and the background job don't both
  /// run.
  bool _claim(DateTime now) => _store.transaction(() {
    const lastRun = CodeCleanupSettings.lastRunSetting;
    if (lastRun.read(_store.settings) case final last?) {
      final since = now.difference(last);
      // A clock set back by more than an hour doesn't stop it for good.
      if (since < interval && since > -interval) return false;
    }
    lastRun.write(_store.settings, now);
    return true;
  });
}
