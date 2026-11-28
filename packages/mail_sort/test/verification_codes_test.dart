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

  group('numbers that are not codes', () {
    test('a group of a longer grouped number', () {
      const cases = [
        // A rail booking code in four groups.
        ('Booking code: 1111 2222 3333 4444 Customer no.: XY000000000 '
            'Travel date: 3 March 2031'),
        // Zoom (3-4-4) and Teams (3-3-3-3) meeting IDs.
        ('Join Zoom Meeting\nhttps://example.zoom.us/j/98765432101?pwd=abc\n\n'
            'Meeting ID: 987 6543 2101\nPasscode: Qw3&er45'),
        'Microsoft Teams meeting\nMeeting ID: 321 654 987 210\nPasscode: Zx9',
        'Call our code hotline +99 6123 4567 any time',
      ];
      for (final text in cases) {
        expect(VerificationCodes.find(text), isNull, reason: text);
      }
    });

    test('a booking, order or promo code after its label', () {
      const cases = [
        ('Check-in QR code\nBooking Reference Number\n[barcode]\nK7QZ2P\n'
            'Show this at the counter.'),
        'Your reservation code: ZX81QA. Use it to manage your booking.',
        'Order number 55512345 (keep this code for returns)',
        "Use promo code 'SPRING50' when you pay to get \$10 off",
        "Mention code 'PERK20' at the bar for 15% off drinks.",
        'Enter code SALE2031 at checkout',
        'Backup failed. Error code: 0x80070005',
      ];
      for (final text in cases) {
        expect(VerificationCodes.find(text), isNull, reason: text);
      }
    });

    test('a meeting passcode, and a year near "password-protected"', () {
      const cases = [
        'Meeting ID 901 2345 6789\nPasscode 246810\nJoin Meeting',
        'Webinar ID 222 3333 4444\nPasscode 123456',
        'Starts: 4 March 2031 09:00\nClick Here to Join\nPasscode: 271828',
        'Statement for March 2031. The attached PDF is password-protected.',
      ];
      for (final text in cases) {
        expect(VerificationCodes.find(text), isNull, reason: text);
      }
    });

    test('a postcode in a sign-in link mail\'s footer', () {
      const text =
          'Tap the button to verify and sign in. This link works once. '
          'Verify\nExample Travel B.V., Voorbeeldstraat 12, 1234 AB Amsterdam';
      expect(VerificationCodes.find(text), isNull);
      expect(VerificationCodes.inMessage('Your verification link', text), null);
      expect(
        VerificationCodes.isVerificationSubject('Your verification link'),
        isTrue,
      );
    });

    test('real codes next to such numbers are still found', () {
      final cases = {
        'Your booking number is 55512345. Your verification code: 654321':
            '654321',
        'Your verification code is 482913. Get 20% off your next ride!':
            '482913',
        'Meeting notes attached. Your sign-in code is 778899': '778899',
        'Use code 820193 to sign in.': '820193',
        'Your code: 2031': '2031',
      };
      for (final MapEntry(key: text, value: code) in cases.entries) {
        expect(VerificationCodes.find(text), code, reason: text);
      }
    });

    test('a rail booking or a meeting invite is not sorted as Codes', () {
      expect(
        const HeaderRuleClassifier()
            .classify(
              mail(
                'Example Rail ticket – 1111 2222 3333 4444 – Mar 3 2031',
                snippet:
                    'Booking code: 1111 2222 3333 4444 Customer no.: '
                    'XY000000000 Travel date: 3 March 2031',
              ),
            )
            .category,
        isNot(MessageCategory.codes),
      );
      expect(
        const HeaderRuleClassifier()
            .classify(
              mail(
                'Team discussion',
                snippet:
                    'Join Zoom Meeting https://example.zoom.us/j/98765432101 '
                    'Meeting ID: 987 6543 2101 Passcode: 445566',
              ),
            )
            .category,
        isNot(MessageCategory.codes),
      );
    });

    test('an order\'s "email confirmation" is not verification mail', () {
      expect(
        VerificationCodes.isVerificationSubject(
          'Email confirmation for your Example Burgers order',
        ),
        isFalse,
      );
      expect(
        VerificationCodes.isVerificationSubject('Email confirmation'),
        isTrue,
      );
      expect(
        VerificationCodes.isVerificationSubject('Your order verification code'),
        isTrue,
      );
    });
  });

  group('codes in Chinese, and in lower case', () {
    test('a Traditional or Simplified Chinese code label', () {
      final cases = {
        '您的驗證碼為 482913，請於10分鐘內輸入。': '482913',
        '請在頁面輸入以下認證碼以重設密碼。認證碼：7k2m9q': '7k2m9q',
        '您的认证码：731942': '731942',
      };
      for (final MapEntry(key: text, value: code) in cases.entries) {
        expect(VerificationCodes.find(text), code, reason: text);
      }
      for (final subject in ['您的驗證碼', 'Example 認證碼通知', '验证码']) {
        expect(
          VerificationCodes.isVerificationSubject(subject),
          isTrue,
          reason: subject,
        );
      }
    });

    test('a lower-case code on its own line', () {
      expect(
        VerificationCodes.find(
          'Choose a new password\nEnter this code to continue:\n\nq4w8e2rt\n\n'
          'It is valid for 15 minutes.',
        ),
        'q4w8e2rt',
      );
      expect(
        VerificationCodes.find('Your code is valid for 10 minutes'),
        isNull,
      );
      expect(
        VerificationCodes.find('Verify your address. Username: bob1990'),
        isNull,
      );
    });
  });

  test('a sign-in notice with the code far down its body', () {
    const body =
        'Security Notice for User p******7: Verify Log In\n'
        'Dear Client,\n'
        'We noticed a log in to your account from a new device or location.\n'
        'Security Alert: Financial institutions are being impersonated '
        'through text messages, emails and phone calls.\n'
        'Action Required:\n'
        '- If you suspect unauthorized access, please contact our support '
        'team directly\n'
        '- If this login was legitimate, use this verification code to '
        'access your account: 327570\n'
        'Licence No: CMS100917. Message Reference Number: '
        '5-17946356529180006-789728';
    expect(
      VerificationCodes.inMessage(
        'Security Notice for User p******7: Verify Log In',
        body,
      ),
      '327570',
    );
  });

  test('codes in Uber, SimplyGo and Google emails', () {
    expect(
      VerificationCodes.inMessage(
        'Your Uber account verification code',
        'Your Uber verification code\nHi Robin,\nTo finish logging in to '
            'your Uber account, enter this verification code:\nDo not share '
            'this code with anyone. Uber staff will never ask you for this '
            'code.\n9514\nIf you didn\'t make this request or you need '
            'assistance, visit our Help Center.',
      ),
      '9514',
    );
    expect(
      VerificationCodes.inMessage(
        'Email Validation Code - One Time Password',
        'Dear Account Holder,\nYou have requested for a One-time Password '
            '(OTP).\nYour OTP is 7974.\nIf you did not make this request, '
            'please contact our hotline at 1800-2255 663.',
      ),
      '7974',
    );
    expect(
      VerificationCodes.inMessage(
        'Google Verification Code',
        'Google Verification Code\nHi Robin,\nWe received a request to '
            'access your Google Account robin.vale@example.com through your '
            'email address. Your Google verification code is:\n155031\nIf '
            'you did not request this code, it is possible that someone else '
            'is trying to access the Google Account.',
      ),
      '155031',
    );
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
        'Vale, please verify your new device',
        'Sign in to Slack',
        'Log in to Example',
        '[GitHub] Please verify your device',
        'Two-factor authentication code',
        '123456 is your Instagram code',
        // "Log in" and "sign in" written as two words.
        'Security Notice for User p******7: Verify Log In',
        'Verify your log-in',
        'Please verify sign in',
        'Confirm your sign-in',
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
        'New log in from Chrome on Windows',
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
