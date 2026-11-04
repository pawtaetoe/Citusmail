// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import '../services/app_services.dart';
import 'corrections.dart';

/// The "Your accounts" page's data: online services the user has an
/// account with, found in welcome, sign-in, password and security mail on
/// the device. [readEmails] downloads account emails whose preview says
/// too little, only when the user asks.
final class AccountsModel extends ChangeNotifier {
  AccountsModel(this._services, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AppServices _services;
  final DateTime Function() _now;

  MailStore get _store => _services.store;

  static const _hiddenKey = 'accounts.hidden';

  /// Accounts are old: everything on the device is looked at.
  static const lookBack = Duration(days: 25 * 366);

  /// Not heard from for this long: a candidate to close.
  static const quiet = Duration(days: 2 * 365);

  /// Emails downloaded at most, small ones only.
  static const _readMax = 40;
  static const _maxBytes = 256 * 1024;

  bool loading = true;
  List<OnlineAccount> accounts = const [];

  /// Companies the user said are not accounts.
  Set<String> hidden = const {};

  /// Companies left out because they look like ones the user said are
  /// not accounts ("Learn from my corrections").
  Set<String> learned = const {};

  /// Those of [hidden] and [learned].
  List<OnlineAccount> hiddenOnes = const [];

  /// Everything found.
  List<OnlineAccount> _all = const [];

  late final _corrections = Corrections(_store);

  /// The user's own addresses.
  List<String> ownAddresses = const [];

  /// Account emails not on the device yet whose preview says too little.
  List<int> toRead = const [];

  /// While reading: how many are done, of how many.
  ({int done, int total})? reading;
  bool _stop = false;

  /// Accounts with no mail for [quiet]: worth closing if unused.
  bool isQuiet(OnlineAccount a) => _now().difference(a.lastActivity) > quiet;

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

  Future<void> load() async {
    hidden = {
      ...?_store.settings
          .read(_hiddenKey)
          ?.split(',')
          .where((s) => s.isNotEmpty),
    };
    final mailAccounts = _store.accounts.all();
    ownAddresses = [for (final a in mailAccounts) a.email.toLowerCase()];
    final accountAddress = {
      for (final a in mailAccounts) a.id: a.email.toLowerCase(),
    };
    final candidates = _store.messages.withSubjectWords(
      [...AccountFinder.subjectWords, ...SubscriptionFinder.subjectWords],
      since: _now().subtract(lookBack),
      limit: 5000,
    );
    // Message text off the UI thread: downloaded bodies are parsed.
    final texts = await compute(_texts, [
      for (final m in candidates) (_store.messages.body(m.id), m.snippet),
    ]);
    final people = <String, bool>{};
    bool person(MailAddress from, String registrable) =>
        people[from.normalizedAddress] ??=
            FreeMail.isProvider(registrable) ||
            (!AutomatedSender.matches(from) &&
                _store.messages.hasWrittenTo(from.address));
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
                  for (final a in _store.messages.addresses(m.id, kind))
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
      now: _now(),
    );
    _all = all;
    final messages = {for (final m in candidates) m.id: m};
    learned = await _corrections.vetoed(MailKind.account, {
      for (final a in all)
        if (!hidden.contains(a.company))
          a.company: _samples(a, (id) => messages[id]),
    });
    final left = {...hidden, ...learned};
    accounts = [
      for (final a in all)
        if (!left.contains(a.company)) a,
    ];
    hiddenOnes = [
      for (final a in all)
        if (left.contains(a.company)) a,
    ];
    final sizes = {for (final m in candidates) m.id: m.size};
    toRead = [
      for (final e in emails)
        if (!left.contains(AccountFinder.companyOf(e.company)) &&
            AccountFinder.worthReading(e) &&
            _store.messages.body(e.messageId) == null &&
            (sizes[e.messageId] ?? 0) <= _maxBytes)
          e.messageId,
    ].take(_readMax).toList();
    loading = false;
    notifyListeners();
  }

  /// Downloads the emails in [toRead] from the user's own mail server
  /// (they stay unread), then looks again. Stops early on [stopReading].
  Future<void> readEmails() async {
    if (reading != null || toRead.isEmpty) return;
    final ids = toRead;
    _stop = false;
    var done = 0;
    reading = (done: 0, total: ids.length);
    notifyListeners();
    for (final id in ids) {
      if (_stop) break;
      try {
        await _services.worker.loadBody(id);
      } on Object {
        // Gone, too large or offline: it stays as its preview.
      }
      reading = (done: ++done, total: ids.length);
      notifyListeners();
    }
    reading = null;
    await load();
  }

  void stopReading() => _stop = true;

  /// "Not an account": hidden from the list (undoable), and learned
  /// from.
  void hide(String company) {
    if (_found(company) case final a?) {
      _corrections.rejected(
        MailKind.account,
        _samples(a, _store.messages.byId),
      );
    }
    _setHidden({...hidden, company});
  }

  /// Undo, or "List again": listed again (and never left out by
  /// learning again).
  void unhide(String company) {
    final a = _found(company);
    final samples = a == null
        ? const <MailSample>[]
        : _samples(a, _store.messages.byId);
    if (hidden.contains(company)) {
      _corrections.rejected(MailKind.account, samples, undo: true);
      _setHidden({...hidden}..remove(company));
    } else if (learned.contains(company)) {
      _corrections.kept(MailKind.account, company, samples);
      unawaited(load());
    }
  }

  /// [account]'s page was opened: a weak sign that it is one.
  void opened(OnlineAccount account) => _corrections.opened(
    MailKind.account,
    account.company,
    _samples(account, _store.messages.byId),
  );

  OnlineAccount? _found(String company) =>
      _all.where((a) => a.company == company).firstOrNull;

  /// What the classifier reads of [account]'s emails (the newest few).
  static List<MailSample> _samples(
    OnlineAccount account,
    StoredMessage? Function(int id) message,
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

  void _setHidden(Set<String> companies) {
    _store.settings.write(_hiddenKey, companies.join(','));
    unawaited(load());
  }

  StoredMessage? message(int id) => _store.messages.byId(id);
}

/// Each message's text: the downloaded body when there is one (capped),
/// else its preview.
List<String> _texts(List<(Uint8List?, String?)> messages) => [
  for (final (raw, snippet) in messages)
    if (raw != null)
      () {
        final text = MessageView.parse(raw).body.plainText;
        return text.length > 20000 ? text.substring(0, 20000) : text;
      }()
    else
      snippet ?? '',
];
