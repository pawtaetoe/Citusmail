// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';

import '../../found/state/found_model.dart';
import '../../inbox/state/corrections.dart';
import '../../inbox/state/message_reads.dart';

/// What [findOnlineAccounts] found: every account the rules found
/// ([hidden] and [learned] ones too, by company), the user's own
/// addresses, and the emails worth downloading ([toRead]).
typedef AccountsFound = ({
  List<OnlineAccount> all,
  Set<String> hidden,
  Set<String> learned,
  List<String> ownAddresses,
  List<MessageId> toRead,
});

/// The "Online accounts" page's findings in [store], reading text off the
/// UI thread. The page and reading in the background both use it, so
/// both want the same emails. [toRead] leaves out [skip].
Future<AccountsFound> findOnlineAccounts(
  MailStore store,
  DateTime now, {
  Set<MessageId> skip = const {},
}) async {
  final hidden = {...AccountsModel.hiddenSetting.read(store.settings)};
  final mailAccounts = store.accounts.all();
  final ownAddresses = [for (final a in mailAccounts) a.email.toLowerCase()];
  final accountAddress = {
    for (final a in mailAccounts) a.id: a.email.toLowerCase(),
  };
  final candidates = store.messages.withSubjectWords(
    [...AccountFinder.subjectWords, ...SubscriptionFinder.subjectWords],
    since: now.subtract(AccountsModel.lookBack),
    limit: 5000,
  );
  // Message text off the UI thread: downloaded bodies are parsed.
  final texts = await plainTextReads.read(store, candidates);
  final people = <String, bool>{};
  bool person(MailAddress from, String registrable) =>
      people[from.normalizedAddress] ??=
          FreeMail.isProvider(registrable) ||
          (!AutomatedSender.matches(from) &&
              store.messages.hasWrittenTo(from.address));
  final emails = <AccountEmail>[
    for (final (i, m) in candidates.indexed)
      if (m.from case final from?)
        () {
          final registrable =
              Domains.registrable(from.domain) ?? from.domain.toLowerCase();
          return AccountEmail(
            messageId: m.id,
            company: registrable,
            senderName: from.displayName,
            subject: m.subject ?? '',
            text: texts[i],
            at: m.receivedAt,
            recipients: [
              for (final kind in const ['to', 'cc'])
                for (final a in store.messages.addresses(m.id, kind))
                  a.normalizedAddress,
            ],
            accountAddress: accountAddress[m.accountId],
            fromPerson: person(from, registrable),
            newsletter: m.category == MessageCategory.newsletters,
            code: m.category == MessageCategory.codes,
          );
        }(),
  ];
  final all = AccountFinder.find(
    emails,
    ownAddresses: ownAddresses.toSet(),
    freeMailDomains: FreeMail.providers,
    now: now,
  );
  final messages = {for (final m in candidates) m.id: m};
  final learned = await Corrections(store).vetoed(MailKind.account, {
    for (final a in all)
      if (!hidden.contains(a.company))
        a.company: accountSamples(a, (id) => messages[id]),
  });
  return (
    all: all,
    hidden: hidden,
    learned: learned,
    ownAddresses: ownAddresses,
    toRead: accountMailToRead(
      store,
      candidates,
      emails,
      left: {...hidden, ...learned},
      skip: skip,
    ),
  );
}

/// Account emails of [emails] (read from [candidates]) whose preview says
/// too little and that are not on the device, of companies not in
/// [left]. Small ones only, at most [AccountsModel.readMax]; [skip] left
/// out.
List<MessageId> accountMailToRead(
  MailStore store,
  List<StoredMessage> candidates,
  List<AccountEmail> emails, {
  required Set<String> left,
  Set<MessageId> skip = const {},
}) {
  final sizes = {for (final m in candidates) m.id: m.size};
  return [
    for (final e in emails)
      if (!left.contains(AccountFinder.companyOf(e.company)) &&
          AccountFinder.worthReading(e) &&
          !skip.contains(e.messageId) &&
          !MessageReads.downloaded(store, e.messageId) &&
          (sizes[e.messageId] ?? 0) <= AccountsModel.maxBytes)
        e.messageId,
  ].take(AccountsModel.readMax).toList();
}

/// What the classifier reads of [account]'s emails (the newest few).
List<MailSample> accountSamples(
  OnlineAccount account,
  StoredMessage? Function(MessageId id) message,
) => [
  for (final r in account.records.take(20))
    mailSample(
      message(r.email.messageId),
      domain: r.email.company,
      senderName: r.email.senderName,
      subject: r.email.subject,
      text: r.email.text,
    ),
];

/// The "Online accounts" page's data: online services the user has an
/// account with, found in welcome, sign-in, password and security mail on
/// the device. [readEmails] downloads account emails whose preview says
/// too little, only when the user asks.
final class AccountsModel extends FoundModel<OnlineAccount, AccountsFound> {
  AccountsModel(super.services, {super.now})
    : super(kind: MailKind.account, hiddenKeys: hiddenSetting);

  static const hiddenSetting = StringListSetting('accounts.hidden');

  /// Accounts are old: everything on the device is looked at.
  static const lookBack = Duration(days: 25 * 366);

  /// Not heard from for this long: a candidate to close.
  static const quiet = Duration(days: 2 * 365);

  /// Emails downloaded at most, small ones only.
  static const readMax = 40;
  static const maxBytes = 256 * 1024;

  @override
  Future<AccountsFound> find(DateTime now, Set<MessageId> skip) =>
      findOnlineAccounts(store, now, skip: skip);

  @override
  Finds<OnlineAccount> findsOf(AccountsFound found) => (
    all: found.all,
    hidden: found.hidden,
    learned: found.learned,
    toRead: found.toRead,
  );

  @override
  String keyOf(OnlineAccount item) => item.company;

  @override
  List<MailSample> samplesOf(OnlineAccount item) =>
      accountSamples(item, store.messages.byId);

  /// The accounts listed: those not hidden.
  List<OnlineAccount> get accounts => listed;

  /// The user's own addresses.
  List<String> get ownAddresses => found?.ownAddresses ?? const [];

  /// Accounts with no mail for [quiet]: worth closing if unused.
  bool isQuiet(OnlineAccount a) => now().difference(a.lastActivity) > quiet;

  /// Every address an account uses (plus-addresses included), most used
  /// first.
  List<String> get addressesUsed {
    final counts = <String, int>{};
    for (final a in accounts) {
      for (final address in a.addresses) {
        counts[address] = (counts[address] ?? 0) + 1;
      }
    }
    return counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }
}
