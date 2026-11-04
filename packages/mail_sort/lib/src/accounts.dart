// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'subscriptions.dart';
import 'verification_codes.dart';

/// One email that may show the user has an account somewhere: a welcome,
/// a sign-in code, a password reset, a security alert, a receipt.
final class AccountEmail {
  const AccountEmail({
    required this.messageId,
    required this.company,
    required this.subject,
    required this.text,
    required this.at,
    this.senderName,
    this.recipients = const [],
    this.accountAddress,
    this.fromPerson = false,
    this.newsletter = false,
    this.code = false,
  });

  /// The stored message, to open it.
  final int messageId;

  /// The sender's registrable domain (`google.com` for
  /// `no-reply@accounts.google.com`). Notification domains are mapped to
  /// their company by [AccountFinder].
  final String company;

  /// The sender's display name, if any ("Google").
  final String? senderName;
  final String subject;

  /// What is known of the body: the preview, or the whole text once the
  /// message was downloaded. May be empty.
  final String text;
  final DateTime at;

  /// The To and Cc addresses, lower case.
  final List<String> recipients;

  /// The address of the user's mail account it arrived in, used when none
  /// of [recipients] is the user's (a Bcc).
  final String? accountAddress;

  /// From a person: a free mail address (gmail.com...) or someone the
  /// user writes to. Never a service's account mail.
  final bool fromPerson;

  /// Sorted as a newsletter (mailing list mail).
  final bool newsletter;

  /// In the Codes section: a code, a sign-in link or a reset.
  final bool code;
}

/// What an email shows about an account.
enum AccountEvidence {
  /// A welcome, "confirm your email", "thanks for creating an account".
  signedUp,

  /// A code or link to sign in.
  signInCode,
  passwordReset,

  /// "New sign-in", "security alert", "unusual activity".
  securityAlert,

  /// The email address, password or phone number changed.
  accountChange,

  /// Any other mail about "your account".
  notice,

  /// A receipt, or a paid subscription.
  paid,

  /// "Your account has been deleted".
  closed,
}

/// One email, as understood.
final class AccountRecord {
  const AccountRecord(this.email, this.evidence);

  final AccountEmail email;
  final AccountEvidence evidence;
}

/// When an [AccountEvidence] was seen: first, latest, how many times.
final class EvidenceSpan {
  const EvidenceSpan(this.first, this.latest, this.count);

  final DateTime first;
  final DateTime latest;
  final int count;
}

/// An online service the user has an account with, found in the mail.
final class OnlineAccount {
  const OnlineAccount({
    required this.company,
    required this.name,
    required this.records,
    required this.addresses,
    required this.evidence,
  });

  /// The company's domain (`github.com`).
  final String company;

  /// What to call it: the sender name most used, else the domain.
  final String name;

  /// Its account emails, newest first.
  final List<AccountRecord> records;

  /// The user's addresses it writes to, most used first (with any
  /// `+tag`, as it was given to the service).
  final List<String> addresses;

  /// Each kind of evidence seen.
  final Map<AccountEvidence, EvidenceSpan> evidence;

  /// The newest account email.
  DateTime get lastActivity => records.first.email.at;

  /// The oldest account email.
  DateTime get firstSeen => records.last.email.at;

  /// When the user signed up, if a welcome or confirmation was found.
  DateTime? get signedUp => evidence[AccountEvidence.signedUp]?.first;

  /// The latest email is about the account being closed (nothing came
  /// after it but receipts and notices).
  bool get closed {
    final closedAt = evidence[AccountEvidence.closed]?.latest;
    if (closedAt == null) return false;
    return !records.any(
      (r) =>
          r.email.at.isAfter(closedAt) &&
          r.evidence != AccountEvidence.paid &&
          r.evidence != AccountEvidence.notice &&
          r.evidence != AccountEvidence.closed,
    );
  }

  bool has(AccountEvidence e) => evidence.containsKey(e);
}

/// Finds the online services the user has an account with, in welcome,
/// sign-in, password and security mail, on the device.
///
/// A company counts when at least one of its emails shows an account
/// (a receipt alone does not: a one-off shop order needs no account, but
/// a paid subscription does). Mail from people, replies and forwards, the
/// user's own domains and newsletters without account wording are left
/// out.
abstract final class AccountFinder {
  /// Subject words of mail worth looking at (also used to pick it from
  /// the store; receipts come with [SubscriptionFinder.subjectWords]).
  static const subjectWords = [
    'welcome',
    'verify',
    'verification',
    'confirm',
    'activate',
    'account',
    'password',
    'sign-in',
    'sign in',
    'signin',
    'signed in',
    'log in',
    'login',
    'log-in',
    'logged in',
    'code',
    'security',
    'new device',
    'registration',
    'sign up',
    'signed up',
    'signing up',
    'email address',
    'e-mail address',
    'deleted',
    'closed',
    'deactivated',
    '2-step',
    'two-factor',
  ];

  /// Notification domains that belong to another company's domain.
  /// Sub-domains (`accounts.google.com`, `mail.instagram.com`) need no
  /// entry: the registrable domain already groups them.
  static const aliases = {
    'facebookmail.com': 'facebook.com',
    'googlemail.com': 'google.com',
    'youtube.com': 'google.com',
    'redditmail.com': 'reddit.com',
    'twitter.com': 'x.com',
    'microsoftonline.com': 'microsoft.com',
    'live.com': 'microsoft.com',
    'linkedinmail.com': 'linkedin.com',
    'amazon.co.uk': 'amazon.com',
    'amazon.de': 'amazon.com',
    'paypal.co.uk': 'paypal.com',
    'paypal.com.sg': 'paypal.com',
    'grab.com.sg': 'grab.com',
    'grabtaxi.com': 'grab.com',
  };

  /// Names for companies whose senders go by many names ("Google
  /// Accounts", "The Google Account Team"...).
  static const names = {
    'google.com': 'Google',
    'apple.com': 'Apple',
    'microsoft.com': 'Microsoft',
    'facebook.com': 'Facebook',
    'instagram.com': 'Instagram',
    'github.com': 'GitHub',
    'amazon.com': 'Amazon',
    'x.com': 'X (Twitter)',
    'linkedin.com': 'LinkedIn',
    'reddit.com': 'Reddit',
    'paypal.com': 'PayPal',
    'netflix.com': 'Netflix',
    'grab.com': 'Grab',
  };

  /// The company a registrable sender domain belongs to.
  static String companyOf(String registrable) {
    final domain = registrable.toLowerCase();
    return aliases[domain] ?? domain;
  }

  static final _closed = RegExp(
    r'\b(?:account (?:has been|was|is now|is) (?:permanently )?'
    r'(?:deleted|closed|deactivated|terminated|removed)|'
    r'(?:deleted|closed|deactivated) your (?:\w+ )?account|'
    r'account (?:deletion|closure) (?:confirmed|complete[d]?|confirmation)|'
    r'sorry to see you go)\b',
    caseSensitive: false,
  );

  static final _reset = RegExp(
    r'\b(?:password reset|reset (?:your |my )?(?:\w+ ){0,2}password|'
    r'forgot (?:your )?password|new password request|'
    r'password (?:recovery|reset request)|recover your account)\b',
    caseSensitive: false,
  );

  static final _change = RegExp(
    r'\b(?:(?:password|e-?mail(?: address)?|phone(?: number)?|username|'
    r'recovery (?:email|phone)|security (?:info|information|question)) '
    r'(?:has been |was |is )?(?:changed|updated|added|removed)|'
    r'(?:changed|updated) your (?:\w+ )?(?:password|e-?mail(?: address)?|phone number)|'
    r'(?:new|updated) (?:e-?mail address|recovery (?:email|phone))|'
    r'(?:two-factor|2-step|two-step) (?:authentication |verification )?'
    r'(?:is |has been |was )?(?:enabled|disabled|turned (?:on|off)|on|off)|'
    r'(?:ssh|gpg|api|security) key (?:was |has been )?(?:added|removed|deleted)|'
    r'a new (?:ssh|gpg|public) key|personal access token)\b',
    caseSensitive: false,
  );

  static final _alert = RegExp(
    r'\b(?:new (?:sign-in|sign in|signin|login|log-in|log in|device)|'
    r'security alert|security notice|security notification|'
    r'(?:suspicious|unusual|unrecognized|unrecognised) '
    r'(?:sign-in|sign in|login|log-in|activity|device)|'
    r'(?:signed|logged) in (?:from|on) (?:a )?new|'
    r'sign-in (?:attempt|from)|login attempt|'
    r'was this you|someone (?:signed|logged) in|'
    r'your (?:\w+ )?(?:id|account) was used to sign in)\b',
    caseSensitive: false,
  );

  static final _signedUp = RegExp(
    r'\b(?:welcome to|welcome aboard|welcome,|'
    r'(?:verify|confirm|activate) (?:your |this )?(?:new )?'
    r'(?:\w+ )?(?:e-?mail|e-?mail address|account|registration)|'
    r'(?:e-?mail|account) (?:verification|confirmation)|'
    r'thanks? (?:you )?for (?:signing up|joining|registering|creating)|'
    r'(?:your|new) (?:\w+ )?account (?:has been |is |was )?(?:created|ready|activated|set up)|'
    r'account (?:created|activated)|'
    r'complete your (?:registration|sign[- ]?up|account)|'
    r'finish (?:setting up|creating) your (?:\w+ )?account|'
    r'registration (?:confirmed|successful|complete))',
    caseSensitive: false,
  );

  /// "Welcome back" is a sign-in, not a sign-up.
  static final _welcomeBack = RegExp(r'\bwelcome back\b', caseSensitive: false);

  /// The subject speaks of the user's account.
  static final _accountSubject = RegExp(
    r"\b(?:your (?:[\w.&'-]+ ){0,2}(?:account|id|profile|membership)|"
    r'account (?:update|notice|information|statement|summary|activity))\b',
    caseSensitive: false,
  );

  /// The text speaks of an account the user holds there.
  static final _accountText = RegExp(
    r"\b(?:your (?:[\w.&'-]+ ){0,2}account|sign in to your|log in to your|"
    r'manage your account|account settings)\b',
    caseSensitive: false,
  );

  /// A newsletter's own sign-up: no account.
  static final _newsletterWords = RegExp(
    r'\b(?:newsletters?|mailing list|digest|subscribe|subscription to our|'
    r'our list|updates from)\b',
    caseSensitive: false,
  );

  /// Marketing that borrows account words ("Welcome to summer savings").
  static final _promotion = RegExp(
    r'\b(?:\d+% off|sale|deals?|discount|promo|voucher|coupon|offer)\b',
    caseSensitive: false,
  );

  /// What [email] shows about an account, or null.
  static AccountEvidence? evidenceOf(AccountEmail email) {
    final subject = email.subject;
    if (SubscriptionFinder.isReplyOrForward(subject) || email.fromPerson) {
      return null;
    }
    final text = email.text;
    final both = '$subject\n$text';
    if (_closed.hasMatch(both)) return AccountEvidence.closed;
    if (_reset.hasMatch(subject)) return AccountEvidence.passwordReset;
    if (_change.hasMatch(subject)) return AccountEvidence.accountChange;
    if (_alert.hasMatch(subject)) return AccountEvidence.securityAlert;
    final promotion = _promotion.hasMatch(subject);
    if (!promotion && _isSignUp(subject, text, email.newsletter)) {
      return AccountEvidence.signedUp;
    }
    if (email.code ||
        VerificationCodes.isVerificationSubject(subject) ||
        (!promotion &&
            VerificationCodes.inMessage(subject, text) != null &&
            VerificationCodes.isVerificationText(text))) {
      if (_reset.hasMatch(text)) return AccountEvidence.passwordReset;
      return AccountEvidence.signInCode;
    }
    if (_isReceipt(email)) return AccountEvidence.paid;
    if (promotion || email.newsletter) return null;
    if (_accountSubject.hasMatch(subject)) return AccountEvidence.notice;
    // A body that names the change or alert, under a plain subject
    // ("Security update", "Important notice").
    if (_plainSubject.hasMatch(subject)) {
      if (_change.hasMatch(text)) return AccountEvidence.accountChange;
      if (_alert.hasMatch(text)) return AccountEvidence.securityAlert;
    }
    return null;
  }

  static bool _isSignUp(String subject, String text, bool newsletter) {
    if (_welcomeBack.hasMatch(subject)) return false;
    if (!_signedUp.hasMatch(subject) &&
        !(subject.isEmpty && _signedUp.hasMatch(text))) {
      // "Thanks for creating an account" may be in the text only.
      if (!_signedUpText.hasMatch(text)) return false;
    }
    // A newsletter's welcome ("Welcome to the Weekly Digest", "Confirm
    // your subscription") is not an account, unless its text says so.
    if (newsletter || _newsletterWords.hasMatch(subject)) {
      return _accountText.hasMatch(text) && !_newsletterWords.hasMatch(subject);
    }
    return true;
  }

  /// Sign-up wording strong enough in the text alone.
  static final _signedUpText = RegExp(
    r'\b(?:thanks? (?:you )?for (?:signing up|creating (?:an|your) (?:\w+ )?account|registering)|'
    r'(?:your|new) (?:\w+ )?account (?:has been |is |was )?(?:created|activated)|'
    r'(?:verify|confirm) your (?:e-?mail|e-?mail address) to (?:finish|complete|activate|get started))',
    caseSensitive: false,
  );

  static bool _isReceipt(AccountEmail email) =>
      SubscriptionFinder.eventOf(_asSubscriptionEmail(email)) ==
          SubscriptionEvent.charge &&
      _receiptSubject.hasMatch(email.subject);

  static final _receiptSubject = RegExp(
    '\\b(?:${SubscriptionFinder.subjectWords.map(RegExp.escape).join('|')})',
    caseSensitive: false,
  );

  static SubscriptionEmail _asSubscriptionEmail(AccountEmail e) =>
      SubscriptionEmail(
        messageId: e.messageId,
        company: companyOf(e.company),
        senderName: e.senderName,
        subject: e.subject,
        text: e.text,
        at: e.at,
      );

  static final _plainSubject = RegExp(
    r'\b(?:security|important|alert|update|notice|action required)\b',
    caseSensitive: false,
  );

  /// Whether [email] may show an account once its whole text is read:
  /// a welcome or account mail whose preview says too little.
  static bool worthReading(AccountEmail email) {
    if (email.fromPerson ||
        SubscriptionFinder.isReplyOrForward(email.subject)) {
      return false;
    }
    if (evidenceOf(email) != null) return false;
    return RegExp(
      r'\b(?:welcome|account|registration|signed up)\b',
      caseSensitive: false,
    ).hasMatch(email.subject);
  }

  /// The accounts in [emails] (any order), most recently active first.
  ///
  /// [ownAddresses] are the user's mail addresses (lower case): mail sent
  /// from their domains is left out (unless it is a free mail service),
  /// and the address each account uses is picked among them (with any
  /// `+tag`); [freeMailDomains] are never the user's own. [now] is
  /// today.
  static List<OnlineAccount> find(
    Iterable<AccountEmail> emails, {
    Set<String> ownAddresses = const {},
    Set<String> freeMailDomains = const {},
    DateTime? now,
  }) {
    final own = {for (final a in ownAddresses) a.toLowerCase()};
    final ownDomains = {
      for (final a in own)
        if (a.contains('@')) a.substring(a.lastIndexOf('@') + 1),
    }..removeAll(freeMailDomains);
    bool ownDomain(String company) =>
        ownDomains.any((d) => d == company || d.endsWith('.$company'));

    final byCompany = <String, List<AccountEmail>>{};
    for (final e in emails) {
      final company = companyOf(e.company);
      if (company.isEmpty || ownDomain(company)) continue;
      byCompany.putIfAbsent(company, () => []).add(e);
    }

    // Paid subscriptions: an account by themselves.
    final subscribed = {
      for (final s in SubscriptionFinder.find([
        for (final list in byCompany.values)
          for (final e in list)
            if (!e.fromPerson && _receiptSubject.hasMatch(e.subject))
              _asSubscriptionEmail(e),
      ], now: now ?? DateTime.now().toUtc()))
        s.company,
    };

    final found = <OnlineAccount>[];
    for (final MapEntry(key: company, value: list) in byCompany.entries) {
      final records = <AccountRecord>[
        for (final e in list)
          if (evidenceOf(e) case final evidence?) AccountRecord(e, evidence),
      ]..sort((a, b) => b.email.at.compareTo(a.email.at));
      // A receipt alone may be a one-off order: it shows an account only
      // for a subscription, or when it speaks of the account.
      final shows = records.any(
        (r) =>
            r.evidence != AccountEvidence.paid ||
            subscribed.contains(company) ||
            _accountText.hasMatch(r.email.text),
      );
      if (!shows) continue;
      final evidence = <AccountEvidence, EvidenceSpan>{};
      for (final r in records.reversed) {
        final at = r.email.at;
        final span = evidence[r.evidence];
        evidence[r.evidence] = span == null
            ? EvidenceSpan(at, at, 1)
            : EvidenceSpan(span.first, at, span.count + 1);
      }
      found.add(
        OnlineAccount(
          company: company,
          name: _name(company, records),
          records: List.unmodifiable(records),
          addresses: _addresses(records, own),
          evidence: Map.unmodifiable(evidence),
        ),
      );
    }
    found.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return found;
  }

  /// The user's addresses [records] were sent to, most used first.
  static List<String> _addresses(List<AccountRecord> records, Set<String> own) {
    final counts = <String, int>{};
    for (final r in records) {
      final to = r.email.recipients
          .map((a) => a.toLowerCase())
          .where((a) => own.isEmpty || own.contains(withoutTag(a)))
          .firstOrNull;
      final address = to ?? r.email.accountAddress?.toLowerCase();
      if (address == null || address.isEmpty) continue;
      counts[address] = (counts[address] ?? 0) + 1;
    }
    return counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  /// `name+shop@example.com` -> `name@example.com`.
  static String withoutTag(String address) {
    final at = address.lastIndexOf('@');
    if (at < 0) return address;
    final local = address.substring(0, at);
    final plus = local.indexOf('+');
    return plus < 0
        ? address
        : '${local.substring(0, plus)}${address.substring(at)}';
  }

  static final _genericName = RegExp(
    r'^(?:no[-_. ]?reply|do[-_. ]?not[-_. ]?reply|support|customer (?:service|support)|'
    r'team|info|hello|notifications?|security|accounts?|billing|admin)$',
    caseSensitive: false,
  );

  /// The sender name most used (not "noreply" or an address), else the
  /// known name, else the domain.
  static String _name(String company, List<AccountRecord> records) {
    if (names[company] case final known?) return known;
    final counts = <String, int>{};
    for (final r in records) {
      final n = r.email.senderName?.trim();
      if (n == null ||
          n.isEmpty ||
          n.contains('@') ||
          _genericName.hasMatch(n)) {
        continue;
      }
      counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) return company;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
}
