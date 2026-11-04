// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

var _id = 0;

AccountEmail mail(
  String company,
  String subject,
  DateTime at, {
  String text = '',
  String? name,
  String to = 'alice@example.org',
  bool person = false,
  bool newsletter = false,
  bool code = false,
}) => AccountEmail(
  messageId: _id++,
  company: company,
  senderName: name,
  subject: subject,
  text: text,
  at: at,
  recipients: [to],
  accountAddress: 'alice@example.org',
  fromPerson: person,
  newsletter: newsletter,
  code: code,
);

DateTime day(int year, int month, [int d = 1]) => DateTime.utc(year, month, d);

const _own = {'alice@example.org', 'alice@work.example'};

List<OnlineAccount> find(List<AccountEmail> emails) => AccountFinder.find(
  emails,
  ownAddresses: _own,
  freeMailDomains: const {'gmail.com'},
  now: day(2026, 11, 4),
);

AccountEvidence? evidence(
  String subject, {
  String text = '',
  bool newsletter = false,
  bool code = false,
}) => AccountFinder.evidenceOf(
  mail(
    'example.com',
    subject,
    day(2026, 1),
    text: text,
    newsletter: newsletter,
    code: code,
  ),
);

void main() {
  group('evidence', () {
    test('welcome and verification mail is a sign-up', () {
      expect(evidence('Welcome to Netflix!'), AccountEvidence.signedUp);
      expect(evidence('Verify your email address'), AccountEvidence.signedUp);
      expect(
        evidence('Please confirm your Shopee account'),
        AccountEvidence.signedUp,
      );
      expect(evidence('Activate your account'), AccountEvidence.signedUp);
      expect(
        evidence(
          'Getting started',
          text:
              'Hi Alice, thanks for creating an account with Grab. '
              'Here is how to book your first ride.',
        ),
        AccountEvidence.signedUp,
      );
      expect(
        evidence('Your Apple ID was created'),
        // "Your Apple ID" alone would be a notice; "created" says more.
        anyOf(AccountEvidence.signedUp, AccountEvidence.notice),
      );
      expect(evidence('Welcome back, Alice'), isNot(AccountEvidence.signedUp));
    });

    test('codes, resets, alerts and changes', () {
      expect(
        evidence('123456 is your Instagram code'),
        AccountEvidence.signInCode,
      );
      expect(
        evidence('Your Netflix sign-in code', code: true),
        AccountEvidence.signInCode,
      );
      expect(
        evidence(
          'Google Verification Code',
          text: 'Your verification code is 482913. Don\'t share it.',
        ),
        AccountEvidence.signInCode,
      );
      expect(
        evidence('[GitHub] Please reset your password'),
        AccountEvidence.passwordReset,
      );
      expect(
        evidence('Reset your Apple ID password'),
        AccountEvidence.passwordReset,
      );
      expect(evidence('Security alert'), AccountEvidence.securityAlert);
      expect(
        evidence('New sign-in to your Netflix account'),
        AccountEvidence.securityAlert,
      );
      expect(
        evidence(
          'Your Apple ID was used to sign in to iCloud via a web browser',
        ),
        AccountEvidence.securityAlert,
      );
      expect(
        evidence('[GitHub] A new SSH key was added to your account'),
        AccountEvidence.accountChange,
      );
      expect(
        evidence('Your password was changed'),
        AccountEvidence.accountChange,
      );
      expect(
        evidence('Your email address has been updated'),
        AccountEvidence.accountChange,
      );
      expect(evidence('Your account has been deleted'), AccountEvidence.closed);
      expect(
        evidence(
          'Goodbye from Example',
          text: "We're sorry to see you go. We have closed your account.",
        ),
        AccountEvidence.closed,
      );
      expect(evidence('Your DBS account statement'), AccountEvidence.notice);
    });

    test('not account mail', () {
      expect(evidence('Re: Welcome to the team'), isNull);
      expect(evidence('Fwd: Your password was changed'), isNull);
      expect(evidence('Weekend sale: 30% off everything'), isNull);
      expect(evidence('Welcome to summer: 20% off'), isNull);
      expect(
        evidence('Welcome to the Weekly Digest', newsletter: true),
        isNull,
      );
      expect(evidence('Confirm your newsletter subscription'), isNull);
      expect(
        evidence('Your promo code: SAVE20 inside', text: 'Use code SAVE2026'),
        isNull,
      );
      expect(
        evidence(
          '[octo/widgets] Login fails after upgrade (#42)',
          text:
              'Since 2.0 the password was changed field is ignored and a '
              'new sign-in is required.',
        ),
        isNull,
      );
    });
  });

  group('find', () {
    test('groups a company\'s senders and keeps its evidence dates', () {
      final found = find([
        mail(
          'google.com', // accounts.google.com
          'Security alert',
          day(2026, 10, 2),
          name: 'Google',
          text: 'New sign-in on Windows. alice@example.org',
        ),
        mail(
          'google.com',
          'Welcome to your new Google Account',
          day(2019, 3, 5),
          name: 'Google Community Team',
        ),
        mail(
          'google.com',
          'Google Verification Code',
          day(2024, 6, 1),
          text: 'Your verification code is 482913',
        ),
        mail(
          'youtube.com',
          'Your YouTube channel was deleted',
          day(2025, 1, 1),
          text: 'Your account has been deleted as you asked.',
        ),
      ]);
      expect(found, hasLength(1));
      final google = found.single;
      expect(google.company, 'google.com');
      expect(google.name, 'Google');
      expect(google.records, hasLength(4));
      expect(google.signedUp, day(2019, 3, 5));
      expect(google.lastActivity, day(2026, 10, 2));
      expect(
        google.evidence[AccountEvidence.securityAlert]!.latest,
        day(2026, 10, 2),
      );
      expect(google.has(AccountEvidence.signInCode), isTrue);
      // A sign-in came after the deletion: still open.
      expect(google.closed, isFalse);
      expect(google.addresses, ['alice@example.org']);
    });

    test('well-known services, plus-addresses and several addresses', () {
      final found = find([
        mail(
          'apple.com',
          'Welcome to Apple ID',
          day(2018, 4, 2),
          name: 'Apple',
          to: 'alice@example.org',
        ),
        mail(
          'apple.com',
          'Your Apple ID was used to sign in to iCloud via a web browser',
          day(2026, 8, 30),
          name: 'Apple',
        ),
        mail(
          'github.com',
          '[GitHub] Please verify your email address',
          day(2020, 2, 1),
          name: 'GitHub',
          to: 'alice@work.example',
        ),
        mail(
          'github.com',
          '[GitHub] A new SSH key was added to your account',
          day(2026, 9, 12),
          name: 'GitHub',
          to: 'alice@work.example',
        ),
        // Someone else's discussion: not account mail.
        mail(
          'github.com',
          'Re: [octo/widgets] Password reset form crashes (#77)',
          day(2026, 11, 1),
          name: 'Bob',
          to: 'alice@work.example',
        ),
        mail(
          'netflix.com',
          'Your Netflix sign-in code',
          day(2026, 10, 20),
          name: 'Netflix',
          code: true,
        ),
        mail(
          'shopee.sg',
          'Please confirm your Shopee account',
          day(2021, 3, 14),
          name: 'Shopee',
          to: 'Alice+shopee@example.org',
        ),
        mail(
          'shopee.sg',
          'Your OTP for Shopee',
          day(2026, 10, 1),
          name: 'Shopee',
          text: 'Your Shopee OTP is 553201. It expires in 5 minutes.',
          to: 'alice+shopee@example.org',
        ),
        mail(
          'grab.com',
          'Welcome to Grab!',
          day(2022, 7, 7),
          name: 'Grab',
          text: 'Thanks for signing up. Your account is ready.',
        ),
        mail(
          'dbs.com',
          'DBS iBanking: New device registered',
          day(2025, 5, 5),
          name: 'DBS Bank',
        ),
        mail(
          'dbs.com',
          'Your DBS account statement for April',
          day(2025, 5, 3),
          name: 'DBS Bank',
        ),
      ]);
      // Most recent first (the reply of Nov 1 is left out).
      expect(
        [for (final a in found) a.name],
        ['Netflix', 'Shopee', 'GitHub', 'Apple', 'DBS Bank', 'Grab'],
      );
      final byName = {for (final a in found) a.name: a};
      expect(byName['GitHub']!.addresses, ['alice@work.example']);
      expect(byName['GitHub']!.records, hasLength(2));
      expect(byName['GitHub']!.lastActivity, day(2026, 9, 12));
      expect(byName['Shopee']!.addresses, ['alice+shopee@example.org']);
      expect(byName['Shopee']!.signedUp, day(2021, 3, 14));
      expect(
        byName['Shopee']!.evidence[AccountEvidence.signInCode]!.latest,
        day(2026, 10, 1),
      );
      expect(byName['Apple']!.signedUp, day(2018, 4, 2));
      expect(byName['DBS Bank']!.has(AccountEvidence.securityAlert), isTrue);
      expect(byName['DBS Bank']!.has(AccountEvidence.notice), isTrue);
      expect(byName['Grab']!.has(AccountEvidence.signedUp), isTrue);
    });

    test('a closed account', () {
      final found = find([
        mail('oldforum.example', 'Welcome to OldForum', day(2015, 1, 1)),
        mail(
          'oldforum.example',
          'Your account has been deleted',
          day(2023, 6, 1),
        ),
      ]);
      expect(found.single.closed, isTrue);
      expect(found.single.name, 'oldforum.example');
    });

    test('receipts count as paid, an account only with account wording', () {
      final found = find([
        // A one-off shop: a receipt, nothing about an account.
        mail(
          'flowershop.example',
          'Your receipt from Flower Shop',
          day(2026, 2, 14),
          name: 'Flower Shop',
          text: 'Thank you for your order. Total S\$45.00',
        ),
        // A shop where the user has an account.
        mail(
          'books.example',
          'Your order receipt',
          day(2026, 3, 1),
          name: 'Books',
          text: 'Total S\$22.00. Sign in to your account to track it.',
        ),
        // A paid subscription needs an account.
        for (final m in [8, 9, 10])
          mail(
            'netflix.com',
            'Your Netflix receipt',
            day(2026, m, 5),
            name: 'Netflix',
            text: 'Your membership has been renewed. Total S\$17.98',
          ),
        // A shop with a welcome and a receipt.
        mail('lazada.sg', 'Welcome to Lazada', day(2020, 1, 1)),
        mail(
          'lazada.sg',
          'Payment confirmation for order 12345',
          day(2026, 4, 1),
          text: 'Total paid S\$12.00',
        ),
      ]);
      final names = {for (final a in found) a.company};
      expect(names, isNot(contains('flowershop.example')));
      expect(names, containsAll(['books.example', 'netflix.com', 'lazada.sg']));
      final lazada = found.firstWhere((a) => a.company == 'lazada.sg');
      expect(lazada.has(AccountEvidence.paid), isTrue);
      expect(lazada.has(AccountEvidence.signedUp), isTrue);
      final netflix = found.firstWhere((a) => a.company == 'netflix.com');
      expect(netflix.evidence[AccountEvidence.paid]!.count, 3);
    });

    test('leaves out people, newsletters and the user\'s own domains', () {
      final found = find([
        // A friend.
        mail(
          'gmail.com',
          'Welcome to the neighbourhood!',
          day(2026, 5, 1),
          name: 'Carol',
          person: true,
        ),
        // A newsletter's welcome without an account.
        mail(
          'substack.example',
          'Welcome to The Weekly Digest',
          day(2026, 5, 2),
          newsletter: true,
          text: 'Thanks for subscribing! Every Sunday we send...',
        ),
        // Work IT: the user's own domain.
        mail(
          'work.example',
          'Your password will expire: reset your password',
          day(2026, 5, 3),
        ),
        // A forwarded reset.
        mail('example.net', 'Fwd: Reset your password', day(2026, 5, 4)),
      ]);
      expect(found, isEmpty);
    });

    test('a newsletter welcome that speaks of an account counts', () {
      final found = find([
        mail(
          'medium.com',
          'Welcome to Medium',
          day(2026, 5, 2),
          newsletter: true,
          text: 'Your account is ready. Manage your account settings any time.',
        ),
      ]);
      expect(found.single.has(AccountEvidence.signedUp), isTrue);
    });

    test('notification domains map to their company', () {
      expect(AccountFinder.companyOf('facebookmail.com'), 'facebook.com');
      expect(AccountFinder.companyOf('Instagram.com'), 'instagram.com');
      final found = find([
        mail(
          'facebookmail.com',
          'New login to Facebook from Chrome on Mac',
          day(2026, 6, 1),
          name: 'Facebook',
        ),
        mail(
          'facebook.com',
          'Welcome to Facebook',
          day(2012, 6, 1),
          name: 'Facebook',
        ),
      ]);
      expect(found.single.company, 'facebook.com');
      expect(found.single.records, hasLength(2));
    });

    test('a Bcc uses the account the mail arrived in', () {
      final found = find([
        AccountEmail(
          messageId: 1,
          company: 'example.com',
          subject: 'Verify your email',
          text: '',
          at: day(2026, 1),
          recipients: const ['undisclosed-recipients@example.com'],
          accountAddress: 'alice@work.example',
        ),
      ]);
      expect(found.single.addresses, ['alice@work.example']);
    });

    test('worth reading: a welcome whose preview says too little', () {
      expect(
        AccountFinder.worthReading(
          mail('tool.example', 'Welcome!', day(2026, 1), newsletter: true),
        ),
        isTrue,
      );
      expect(
        AccountFinder.worthReading(mail('x.example', 'Lunch?', day(2026, 1))),
        isFalse,
      );
    });
  });
}
