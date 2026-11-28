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
    r'|(?:verify|confirm|activate) (?:your |this )?(?:new )?(?:email|e-mail|email address|e-mail address|account|identity|device|sign-in|sign in|signin|login|log-in|log in)'
    r'|(?:email|e-mail|account) (?:verification|confirmation)'
    r'|(?:sign-in|sign in|login|log-in|log in|magic|verification) link'
    r')\b'
    r'|验证码|驗證碼|认证码|認證碼|校验码|校驗碼|动态密码|動態密碼|一次性密码|一次性密碼|'
    r'認証コード|確認コード|인증 ?번호|인증 ?코드',
    caseSensitive: false,
  );

  /// An order's "email confirmation": the order, not the address, is
  /// confirmed.
  static final _orderConfirmation = RegExp(
    r'\b(?:e-?mail|account) confirmation\b',
    caseSensitive: false,
  );
  static final _order = RegExp(
    r'\b(?:order|orders|ordering|ordered|purchase)\b',
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
    r'\b(?:code|codes|otp|passcode|pin|password(?![- ]?protected)|'
    r'verification|verify|kode|código|codice|passwort|bestätigungscode)\b|'
    r'验证码|驗證碼|认证码|認證碼|校验码|校驗碼|动态密码|動態密碼|确认码|確認碼|'
    r'認証コード|確認コード|인증',
    caseSensitive: false,
  );

  /// A keyword right before the code ("code: ", "OTP is ", "驗證碼為").
  static final _rightAfterKeyword = RegExp(
    r'(?:\b(?:code|otp|passcode|pin|kode|código|codice|passwort|'
    r'bestätigungscode)\b|验证码|驗證碼|认证码|認證碼|校验码|校驗碼|'
    r'动态密码|動態密碼|确认码|確認碼|認証コード|確認コード|인증 ?번호)'
    r'\s*(?:is|lautet|est|es|为|為|是)?\s*[:：]?\s*$',
    caseSensitive: false,
  );

  /// A label that makes the number after it something else: a booking
  /// or order reference, a ticket, customer or member number, a promo
  /// code ("Booking code: ...", "Order number 1234", "promo code SAVE").
  static final _label = RegExp(
    r'\b(?:(?:booking|reservation|order|ticket|e-ticket|customer|client|'
    r'member|membership|invoice|tracking|policy|flight|seat|parcel|'
    r'shipment|reference|confirmation)\s*(?:number|no\.?|nr\.?|#|id)|'
    r'(?:booking|reservation|order|ticket|customer|member|membership|'
    r'tracking|flight|promo|promotion|promotional|discount|coupon|voucher|'
    r'referral|gift|reward|bonus|offer|redemption|error|status|product|'
    r'item|postal|zip|course|model|part)\s*(?:code|ref|reference|'
    r'pin)(?:\s*(?:number|no\.?|code))?|'
    r'(?:pnr|booking locator|record locator))\b',
    caseSensitive: false,
  );

  /// A meeting's ID, or a link to join it: its passcode is not a code
  /// to sign in with.
  static final _meeting = RegExp(
    r'\b(?:(?:meeting|webinar|conference)\s*(?:id|number|no\.?)|'
    r'click here to join|tap to join|join (?:now|here|online|by phone)|'
    r'join (?:the |this |our |a )?'
    r'(?:zoom |teams |google meet )?(?:meeting|webinar|call|session)|'
    r'zoom meeting|teams meeting|one tap mobile|dial by your location)\b|'
    r'zoom\.us/[jw]/|teams\.microsoft\.com/l/meetup|meet\.google\.com/',
    caseSensitive: false,
  );

  /// Words that say a code is for signing in or verifying, even next to
  /// a meeting.
  static final _signInWords = RegExp(
    r'\b(?:verification|verify|one-time|one time|otp|sign[- ]?in|log[- ]?in|'
    r'login|2fa|two-factor|authenticat\w*)\b',
    caseSensitive: false,
  );

  /// After a code, in the same clause: a shop's offer ("at checkout",
  /// "for 20% off").
  static final _offerAfter = RegExp(
    r'\b(?:checkout|check-out|discount|savings|cashback|voucher|coupon|'
    r'redeem|promo\w*)\b|\d\s*%|'
    r'\boff (?:your|the|food|drinks|all|any|selected|everything|'
    r'orders?|up to)\b|\bfree (?:delivery|shipping|drinks?|gift)\b',
    caseSensitive: false,
  );

  /// A house number before a 4-digit postcode ("Street 12, 1234 AB Town").
  static final _postcodeAfter = RegExp(
    r'^ ?[A-Z]{2}\s+\p{Lu}\p{Ll}',
    unicode: true,
  );
  static final _clauseEnd = RegExp(r'[.!?\n。！？]');
  static final _digit = RegExp(r'\d');

  /// A code that is not in capitals ("4p8f9k"): letters and digits, with
  /// at least one of each. Taken only right after its label
  /// ("認證碼：4p8f9k") or by itself on a line under one ("code
  /// below:\n\nx7kq2mzp").
  static final _lowerCode = RegExp(
    r'(?<![\w@./:-])[A-Za-z0-9]{4,10}(?![\w@/-]|\.[A-Za-z0-9])',
  );
  static final _letter = RegExp(r'[A-Za-z]');
  static final _lineStart = RegExp(r'(?:^|\n)[ \t]*$');
  static final _lineEnd = RegExp(r'^[ \t]*(?:\n|$)');

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
  /// Not a group of a longer grouped number either (`1111 2222 3333`,
  /// a meeting ID or a phone number).
  static final _code = RegExp(
    r'(?<![\w.,:/@#$€£¥+*-])(?<!\d[ -])'
    r'(?:[A-Z]{1,3}-)?'
    r'(\d{3}[ -]\d{3}|\d{4}[ -]\d{4}|\d{4,8}|'
    r'(?=[A-Z\d]{0,9}\d)(?=[A-Z\d]{0,9}[A-Z])[A-Z\d]{5,10})'
    r'(?![\w,:/@%-]|\.\d|[ -]\d)',
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
    if (_subject.firstMatch(subject) case final m?) {
      // An order's "email confirmation" confirms the order.
      return !(_orderConfirmation.hasMatch(m[0]!) &&
          _order.hasMatch(subject) &&
          !_codeSubject.hasMatch(subject));
    }
    if (_signInTo.hasMatch(subject)) return true;
    // "123456 is your Instagram code", "Your Uber code: 1234".
    return find(subject) != null;
  }

  /// Whether a message preview reads like verification mail: a code with
  /// a keyword next to it, and no promotion.
  static bool isVerificationText(String? text) =>
      text != null && !_promotion.hasMatch(text) && find(text) != null;

  /// The code in [text], spaces and dashes removed, or null. A code
  /// counts only with a keyword ("code", "OTP", "password"...) shortly
  /// before or after it; a 4-digit year is taken only right after one
  /// ("code: 2031"), and only when nothing else is found. Booking, order
  /// and promo codes, meeting IDs and passcodes, and postcodes are not
  /// codes.
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
      if (_somethingElse(before, after, code)) continue;
      if (needsKeyword) {
        if (!_keyword.hasMatch(before) && !_keyword.hasMatch(after)) continue;
      } else if (code.length < 6) {
        continue;
      }
      if (_looksLikeYear(code)) {
        if (needsKeyword && _rightAfterKeyword.hasMatch(before)) {
          fallback ??= code;
        }
        continue;
      }
      return code;
    }
    if (needsKeyword) {
      for (final match in _lowerCode.allMatches(sample)) {
        final code = match[0]!;
        if (!_digit.hasMatch(code) || !_letter.hasMatch(code)) continue;
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
        final labelled = _rightAfterKeyword.hasMatch(before);
        final ownLine =
            code.length >= 6 &&
            _lineStart.hasMatch(before) &&
            _lineEnd.hasMatch(after) &&
            _keyword.hasMatch(before);
        if (!labelled && !ownLine) continue;
        if (_somethingElse(before, after, code)) continue;
        return code;
      }
    }
    return fallback;
  }

  /// Whether the number between [before] and [after] is something other
  /// than a code: a booking, order or promo code after its label, a
  /// meeting's ID or passcode, an offer, or a postcode.
  static bool _somethingElse(String before, String after, String code) {
    final label = _label.allMatches(before).lastOrNull;
    if (label != null) {
      final gap = before.substring(label.end);
      if (gap.length <= 40 &&
          !_digit.hasMatch(gap) &&
          !_keyword.hasMatch(gap)) {
        return true;
      }
    }
    if ((_meeting.hasMatch(before) || _meeting.hasMatch(after)) &&
        !_signInWords.hasMatch(before) &&
        !_signInWords.hasMatch(after)) {
      return true;
    }
    final clause = _clauseEnd.firstMatch(after);
    if (_offerAfter.hasMatch(
      clause == null ? after : after.substring(0, clause.start),
    )) {
      return true;
    }
    return code.length == 4 && _postcodeAfter.hasMatch(after);
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
