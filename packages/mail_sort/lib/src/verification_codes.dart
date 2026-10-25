// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Recognises verification mail (one-time codes, sign-in links, password
/// resets) and finds the code in it. Text only, on the device.
abstract final class VerificationCodes {
  /// Subjects of mail that carries a code or a link to sign in, verify an
  /// address or reset a password.
  static final _subject = RegExp(
    r'\b(?:'
    r'(?:verification|verify|security|login|log-in|log in|sign-in|sign in|signin|'
    r'one-time|one time|confirmation|authentication|access|2fa|mfa)\s+(?:code|pin|passcode)s?'
    r'|one-time password|one time password|otp|passcode|two-factor|two factor|2-step|2fa'
    r'|password reset|reset (?:your |my )?password|forgot (?:your )?password|new password request'
    r'|(?:verify|confirm|activate) (?:your |this )?(?:email|e-mail|email address|e-mail address|account|identity|device|sign-in|login)'
    r'|(?:email|e-mail|account) (?:verification|confirmation)'
    r'|(?:sign-in|sign in|login|log-in|log in|magic) link'
    r')\b',
    caseSensitive: false,
  );

  /// "Sign in to Slack", "Log in to Example": a link or code to sign in
  /// (at the start only, so "New sign-in to your account" alerts are not).
  static final _signInTo = RegExp(
    r'^\s*(?:sign|log)[ -]?in to\b',
    caseSensitive: false,
  );

  /// Words that point at a code nearby.
  static final _keyword = RegExp(
    r'\b(?:code|codes|otp|passcode|pin|password|verification|verify|'
    r'kode|código|codice|passwort|bestätigungscode)\b|验证码|認証コード|인증',
    caseSensitive: false,
  );

  /// A subject that promises a code (not just a link).
  static final _codeSubject = RegExp(
    r'\b(?:code|codes|otp|passcode|pin|one-time password|one time password)\b',
    caseSensitive: false,
  );

  /// Marketing that also says "code".
  static final _promotion = RegExp(
    r'\b(?:promo|promotion|promotional|discount|coupon|voucher|referral|gift|'
    r'offer|sale)\b',
    caseSensitive: false,
  );

  /// Replies and forwards are conversations, not verification mail.
  static final _reply = RegExp(
    r'^\s*(?:re|fw|fwd|aw|wg|sv|vs|tr|rv)\s*(?:\[\d+\])?\s*:',
    caseSensitive: false,
  );

  /// A code: 4 to 8 digits (also as two groups, `123 456`, `1234-5678`),
  /// optionally after a short prefix (`G-123456`, which is left out), or
  /// 5 to 10 capitals and digits with at least one of each (`F7K2P`).
  /// Not part of a longer word, number, amount, time or address.
  static final _code = RegExp(
    r'(?<![\w.,:/@#$€£¥+*-])'
    r'(?:[A-Z]{1,3}-)?'
    r'(\d{3}[ -]\d{3}|\d{4}[ -]\d{4}|\d{4,8}|'
    r'(?=[A-Z\d]{0,9}\d)(?=[A-Z\d]{0,9}[A-Z])[A-Z\d]{5,10})'
    r'(?![\w,:/@%-]|\.\d)',
  );

  /// How far a keyword may be from the code (characters).
  static const _before = 80, _after = 40;

  /// Longest code kept (the store allows 16).
  static const maxLength = 10;

  /// Whether [subject] is a reply or forward.
  static bool isReply(String? subject) =>
      subject != null && _reply.hasMatch(subject);

  /// Whether [subject] is about a code, a sign-in or verification link,
  /// or a password reset (not in a reply or forward, not a promotion).
  static bool isVerificationSubject(String? subject) {
    if (subject == null || subject.isEmpty || _reply.hasMatch(subject)) {
      return false;
    }
    if (_promotion.hasMatch(subject)) return false;
    if (_subject.hasMatch(subject) || _signInTo.hasMatch(subject)) {
      return true;
    }
    // "123456 is your Instagram code", "Your Uber code: 1234".
    return find(subject) != null;
  }

  /// Whether a message preview reads like verification mail: a code with
  /// a keyword next to it, and no promotion.
  static bool isVerificationText(String? text) =>
      text != null && !_promotion.hasMatch(text) && find(text) != null;

  /// The code in [text], spaces and dashes removed, or null. A code
  /// counts only with a keyword ("code", "OTP", "password"...) shortly
  /// before or after it; a 4-digit year is taken only when nothing else
  /// is found.
  static String? find(String? text, {bool needsKeyword = true}) {
    if (text == null || text.isEmpty) return null;
    final sample = text.length > 5000 ? text.substring(0, 5000) : text;
    String? fallback;
    for (final match in _code.allMatches(sample)) {
      final start = match.start;
      final end = match.end;
      final before = sample.substring(
        start - _before < 0 ? 0 : start - _before,
        start,
      );
      final after = sample.substring(
        end,
        end + _after > sample.length ? sample.length : end + _after,
      );
      final code = match.group(1)!.replaceAll(RegExp('[ -]'), '');
      if (code.length > maxLength) continue;
      if (needsKeyword) {
        if (!_keyword.hasMatch(before) && !_keyword.hasMatch(after)) continue;
      } else if (code.length < 6) {
        continue;
      }
      if (_looksLikeYear(code)) {
        fallback ??= code;
        continue;
      }
      return code;
    }
    return fallback;
  }

  /// The code in a message's [subject] or [text] (its preview or body),
  /// subject first. When the subject promises a code ("Your login code"),
  /// the first one of 6 or more characters in [text] counts without a
  /// keyword next to it.
  static String? inMessage(String? subject, String? text) =>
      find(subject) ??
      find(text) ??
      (subject != null && _codeSubject.hasMatch(subject)
          ? find(text, needsKeyword: false)
          : null);

  static bool _looksLikeYear(String code) {
    if (code.length != 4) return false;
    final value = int.tryParse(code);
    return value != null && value >= 1990 && value <= 2099;
  }
}
