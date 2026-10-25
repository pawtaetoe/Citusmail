// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

ClassificationInput mail(
  String subject, {
  String from = 'noreply@service.example',
  String? snippet,
  Map<String, List<String>> headers = const {},
}) {
  final at = from.lastIndexOf('@');
  return ClassificationInput(
    from: MailAddress(
      localPart: from.substring(0, at),
      domain: from.substring(at + 1),
    ),
    headers: headers,
    subject: subject,
    snippet: snippet,
  );
}

void main() {
  group('finding the code', () {
    test('codes next to a keyword, in common shapes', () {
      final cases = {
        '123456 is your Instagram code': '123456',
        'Your verification code is 482913.': '482913',
        'G-551234 is your Google verification code': '551234',
        'Your Slack confirmation code: 123-456': '123456',
        'Use 1234 5678 as your one-time password': '12345678',
        'Your Uber code: 4821. Never share this code.': '4821',
        'Steam Guard code: F7K2P': 'F7K2P',
        'Code de vérification : 739104': '739104',
        'Tu código de verificación es 334455': '334455',
        'Ihr Bestätigungscode lautet 908172': '908172',
        '您的验证码是 667788': '667788',
        'Security code\n\n  204857\n\nIt expires in 10 minutes.': '204857',
      };
      for (final MapEntry(key: text, value: code) in cases.entries) {
        expect(VerificationCodes.find(text), code, reason: text);
      }
    });

    test('no keyword, or not a code: nothing', () {
      for (final text in [
        'Your order 123456 has shipped',
        'Meeting at 10:30 in room 4021?',
        'Total: \$1234.50 with code',
        'Call 1-800-123-4567 for your code',
        'Version 2.4.1234 of the app',
        'Lunch on Friday?',
        'code',
        'Save 20% with this code',
        'Your code expires on 12/10/2026',
        'Email me at code1234@x.example',
      ]) {
        expect(VerificationCodes.find(text), isNull, reason: text);
      }
    });

    test('a year is taken only when nothing else is there', () {
      expect(VerificationCodes.find('© 2026 Example. Your code: 4417'), '4417');
      expect(VerificationCodes.find('Your code 2031'), '2031');
    });

    test('the subject first, then the preview', () {
      expect(
        VerificationCodes.inMessage('Code: 111222', 'Code: 333444'),
        '111222',
      );
      expect(
        VerificationCodes.inMessage('Sign in', 'Your code is 333444'),
        '333444',
      );
      expect(VerificationCodes.inMessage(null, null), isNull);
    });

    test('a subject that promises a code: 6+ characters, no keyword', () {
      const text = 'Hi Alice, use 551200 to sign in. 1600 Main St.';
      expect(VerificationCodes.find(text), isNull);
      expect(VerificationCodes.inMessage('Your login code', text), '551200');
      expect(
        VerificationCodes.inMessage('Reset your password', text),
        isNull,
        reason: 'a link, not a code',
      );
      expect(
        VerificationCodes.inMessage('Your code', 'Visit us at 1600 Main St.'),
        isNull,
      );
    });
  });

  group('verification subjects', () {
    test('codes, sign-in links, password resets and address checks', () {
      for (final subject in [
        'Your verification code',
        'Your Notion login code',
        'One-time passcode for your account',
        'Your OTP',
        'Reset your password',
        'Password reset request',
        'Forgot your password?',
        'Verify your email address',
        'Please confirm your e-mail',
        'Confirm your account',
        'Email verification',
        'Your sign-in link for Linear',
        'Your magic link',
        'Sign in to Slack',
        'Log in to Example',
        '[GitHub] Please verify your device',
        'Two-factor authentication code',
        '123456 is your Instagram code',
      ]) {
        expect(
          VerificationCodes.isVerificationSubject(subject),
          isTrue,
          reason: subject,
        );
      }
    });

    test('replies, forwards, promotions and other mail are not', () {
      for (final subject in [
        'Re: Reset your password',
        'Fwd: Your verification code',
        'AW: Verify your email',
        'Your promo code SAVE2026 inside',
        '20% discount code for you',
        'New sign-in to your account',
        'Your password was changed',
        'Invoice 2026-0041',
        'Lunch on Friday?',
        '',
      ]) {
        expect(
          VerificationCodes.isVerificationSubject(subject),
          isFalse,
          reason: subject,
        );
      }
      expect(VerificationCodes.isVerificationSubject(null), isFalse);
    });
  });

  group('the Codes rule', () {
    const classifier = HeaderRuleClassifier();

    final codes = isA<Classification>()
        .having((c) => c.category, 'category', MessageCategory.codes)
        .having((c) => c.reason, 'reason', SortingReason.verification);

    test('wins over the notification and newsletter rules', () {
      expect(classifier.classify(mail('Your verification code')), codes);
      expect(
        classifier.classify(
          mail(
            'Reset your password',
            from: 'notifications@github.com',
            headers: {
              'list-unsubscribe': ['<https://x.example/u>'],
            },
          ),
        ),
        codes,
      );
    });

    test('a code in the preview counts when the subject says little', () {
      expect(
        classifier.classify(
          mail('Your Example account', snippet: 'Use code 820193 to sign in.'),
        ),
        codes,
      );
      expect(
        classifier
            .classify(mail('Your Example account', snippet: 'Welcome aboard'))
            .category,
        MessageCategory.notifications,
      );
    });

    test('own mail, replies and automatic replies are not codes', () {
      expect(
        classifier
            .classify(
              ClassificationInput(
                from: null,
                headers: const {},
                subject: 'Reset your password',
                mailboxUse: SpecialUse.sent,
              ),
            )
            .category,
        MessageCategory.general,
      );
      expect(
        classifier
            .classify(
              mail(
                'Re: account',
                from: 'friend@x.example',
                snippet: 'my code is 123456',
              ),
            )
            .category,
        MessageCategory.general,
      );
      expect(
        classifier
            .classify(
              mail(
                'Automatic reply: Reset your password',
                from: 'person@x.example',
                headers: {
                  'auto-submitted': ['auto-replied'],
                },
              ),
            )
            .category,
        MessageCategory.general,
      );
    });

    test('a sender of codes does not make their other mail codes', () {
      final learned = LearnedClassifier(
        classifier,
        _History([
          for (var i = 0; i < 5; i++)
            mail('Your login code', from: 'a@b.example'),
        ]),
      );
      expect(
        learned.classify(mail('Your statement', from: 'a@b.example')).category,
        MessageCategory.general,
      );
    });
  });
}

final class _History implements SenderHistory {
  _History(this.mail);

  final List<ClassificationInput> mail;

  @override
  List<ClassificationInput> recentFrom(String address, {int limit = 50}) =>
      mail;

  @override
  bool isCorrespondent(String address) => false;
}
