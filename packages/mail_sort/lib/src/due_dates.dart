// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A date written in an email, and where it is.
typedef DateMention = ({DateTime date, int start, int end});

/// Reads dates from email text: when a bill is due, when a free trial
/// ends. Dates are calendar days (midnight UTC, whatever the time zone).
///
/// Numeric dates are read day first ("15/11/2026" is 15 November), as in
/// Singapore, the UK and most of the world; one that can only be month
/// first ("11/15/2026") is read that way.
abstract final class DueDates {
  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  static const _month =
      r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|'
      r'july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|'
      r'dec(?:ember)?)\.?';

  static const _ordinal = r'(?:st|nd|rd|th)?';

  /// "15 Nov 2026", "15th of November, 2026", "15 Nov" (year optional).
  static final _dayMonth = RegExp(
    '\\b(\\d{1,2})$_ordinal\\s+(?:of\\s+)?$_month(?:,?\\s+(\\d{4}))?\\b',
    caseSensitive: false,
  );

  /// "Nov 15, 2026", "November 15th 2026", "Nov 15".
  static final _monthDay = RegExp(
    '\\b$_month\\s+(\\d{1,2})$_ordinal\\b(?:,?\\s+(\\d{4})\\b)?',
    caseSensitive: false,
  );

  /// "2026-11-15".
  static final _iso = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b');

  /// "15/11/2026", "15-11-2026", "15.11.26".
  static final _numeric = RegExp(
    r'(?<![\d/.-])(\d{1,2})([/.-])(\d{1,2})\2(\d{4}|\d{2})(?![\d/-]|\.\d)',
  );

  /// Every date in [text], in order. A date without a year takes the year
  /// that puts it nearest after [reference] (a little before counts too:
  /// "due 1 Nov" in mail of 3 November).
  static List<DateMention> datesIn(String text, {DateTime? reference}) {
    final found = <DateMention>[];
    bool taken(int start, int end) =>
        found.any((d) => start < d.end && end > d.start);
    void add(int? y, int? m, int? d, int start, int end) {
      if (taken(start, end) || m == null || d == null) return;
      final year = y ?? _yearNear(m, d, reference);
      if (year == null) return;
      final date = _date(year, m, d);
      if (date != null) found.add((date: date, start: start, end: end));
    }

    for (final m in _iso.allMatches(text)) {
      add(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), m.start, m.end);
    }
    for (final m in _numeric.allMatches(text)) {
      var day = int.parse(m[1]!);
      var month = int.parse(m[3]!);
      if (month > 12 && day <= 12) (day, month) = (month, day);
      var year = int.parse(m[4]!);
      if (year < 100) year += 2000;
      add(year, month, day, m.start, m.end);
    }
    for (final m in _dayMonth.allMatches(text)) {
      add(
        m[3] == null ? null : int.parse(m[3]!),
        _monthNumber(m[2]!),
        int.parse(m[1]!),
        m.start,
        m.end,
      );
    }
    for (final m in _monthDay.allMatches(text)) {
      add(
        m[3] == null ? null : int.parse(m[3]!),
        _monthNumber(m[1]!),
        int.parse(m[2]!),
        m.start,
        m.end,
      );
    }
    found.sort((a, b) => a.start.compareTo(b.start));
    return found;
  }

  static int? _monthNumber(String name) =>
      _months[name.substring(0, 3).toLowerCase()];

  static int? _yearNear(int month, int day, DateTime? reference) {
    if (reference == null) return null;
    final ref = dayOf(reference);
    for (final year in [ref.year, ref.year + 1]) {
      final date = _date(year, month, day);
      if (date != null && !date.isBefore(ref.subtract(_yearSlack))) {
        return year;
      }
    }
    return null;
  }

  static const _yearSlack = Duration(days: 60);

  /// A real calendar day, or null ("31/02/2026").
  static DateTime? _date(int year, int month, int day) {
    if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1) {
      return null;
    }
    final date = DateTime.utc(year, month, day);
    return date.month == month && date.day == day ? date : null;
  }

  /// The calendar day of [time] where the user is.
  static DateTime dayOf(DateTime time) {
    final local = time.toLocal();
    return DateTime.utc(local.year, local.month, local.day);
  }

  // ---------------------------------------------------------------- due

  /// Words just before a due date ("Due date:", "Please pay by").
  static final _dueWords = RegExp(
    r'\b(?:due|pay(?:able)?\s+(?:it\s+)?(?:by|before|on or before)|'
    r'payment deadline|deadline|settle(?:d)? (?:it )?by|on or before|'
    r'payment (?:by|before)|'
    r'to be (?:paid|received) (?:by|before)|'
    r'will be (?:debited|deducted|charged) (?:on|from your account on))\b',
    caseSensitive: false,
  );

  /// Labels of other dates on a bill ("Bill date", "Paid on").
  static final _otherDateWords = RegExp(
    r'\b(?:bill(?:ing)? date|invoice date|statement date|issue date|'
    r'date of issue|issued(?: on)?|paid on|payment date|received on|'
    r'billing period|period|from|dated|last payment|previous)\b',
    caseSensitive: false,
  );

  static const _numberWords = {
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'fourteen': 14,
    'fifteen': 15,
    'twenty': 20,
    'thirty': 30,
  };

  static final _count = '(\\d{1,2}|${_numberWords.keys.join('|')})';

  /// "pay your bill within 7 days of receiving this email", "due in 14
  /// days".
  static final _withinDays = RegExp(
    '\\b(?:pay\\w*\\b[^.\\n]{0,60}?\\bwithin|due (?:with)?in)\\s+'
    '$_count(?:\\s*\\(\\d{1,2}\\))?\\s+(?:calendar\\s+|working\\s+|business\\s+)?'
    'days?\\b',
    caseSensitive: false,
  );

  static final _dueToday = RegExp(
    r'\bdue (today|tomorrow)\b',
    caseSensitive: false,
  );

  static int? _number(String word) =>
      int.tryParse(word) ?? _numberWords[word.toLowerCase()];

  /// When [text], a bill received at [received], says it is due: a date
  /// labelled as due ("Due date: 20 Nov 2026", "Please pay by 15/11/2026"),
  /// else "within 7 days of receiving this email" counted from [received].
  /// When several dates are labelled so, the latest (the bill's own, not a
  /// previous one). Null when it says none.
  static DateTime? dueDateIn(String text, {required DateTime received}) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    DateTime? due;
    for (final d in datesIn(sample, reference: received)) {
      final before = sample.substring(
        d.start - 60 < 0 ? 0 : d.start - 60,
        d.start,
      );
      final label = _dueWords.allMatches(before).lastOrNull;
      if (label == null) continue;
      final other = _otherDateWords.allMatches(before).lastOrNull;
      if (other != null && other.start > label.start) continue;
      // "Due" far back on an earlier line labels something else.
      if (before.substring(label.end).contains('\n\n')) continue;
      if (due == null || d.date.isAfter(due)) due = d.date;
    }
    if (due != null) return due;
    final day = dayOf(received);
    if (_withinDays.firstMatch(sample) case final m?) {
      final days = _number(m[1]!);
      if (days != null && days > 0 && days <= 60) {
        return day.add(Duration(days: days));
      }
    }
    if (_dueToday.firstMatch(sample) case final m?) {
      return m[1]!.toLowerCase() == 'today'
          ? day
          : day.add(const Duration(days: 1));
    }
    return null;
  }

  // -------------------------------------------------------------- trials

  /// Words just before the day a trial ends.
  static final _trialEndWords = RegExp(
    r'\b(?:trial\b[^.\n]{0,30}?\b(?:ends?|ending|expires?|over|until)|'
    r'ends?|ending|expires?|until|through|'
    r'(?:charged|billed|renews?|start(?:s|ing)? (?:on|from))|'
    r'first (?:charge|payment|bill)|after)\b',
    caseSensitive: false,
  );

  static final _trialStartWords = RegExp(
    r'\b(?:started|began|activated|joined|signed up|since)\b'
    r'[^.\n]{0,12}$',
    caseSensitive: false,
  );

  /// "ends in 3 days", "ends tomorrow", "ends today".
  static final _trialEndsIn = RegExp(
    '\\b(?:ends?|ending|expires?|is over|will end)\\s+'
    '(?:in\\s+$_count\\s+days?|(today|tomorrow))\\b',
    caseSensitive: false,
  );

  /// "7-day free trial", "1 month free", "30 days for free", "first
  /// month free".
  static final _trialLength = RegExp(
    '\\b(?:$_count|a|first)[\\s-]+(day|week|month|year)s?\\b'
    '(?:[\\s-]+(?:free[\\s-]+)?trial\\b|\\s+(?:for\\s+)?free\\b|'
    '\\s+(?:of|on)\\s+(?:a\\s+)?(?:free|trial))',
    caseSensitive: false,
  );

  /// How long a trial [text] speaks of lasts, as (count, unit) where the
  /// unit is `day`, `week`, `month` or `year`.
  static ({int count, String unit})? trialLengthIn(String text) {
    final m = _trialLength.firstMatch(text);
    if (m == null) return null;
    final word = m[1];
    final count = word == null ? 1 : _number(word);
    if (count == null || count <= 0) return null;
    return (count: count, unit: m[2]!.toLowerCase());
  }

  /// When the free trial [text] (received at [received]) speaks of ends:
  /// a date it gives ("Your trial ends on 12 Nov 2026"), "ends in 3 days",
  /// or the start plus its length ("your 14-day free trial has started").
  static DateTime? trialEndIn(String text, {required DateTime received}) {
    final sample = text.length > 20000 ? text.substring(0, 20000) : text;
    final day = dayOf(received);
    DateTime? end;
    for (final d in datesIn(sample, reference: received)) {
      final before = sample.substring(
        d.start - 50 < 0 ? 0 : d.start - 50,
        d.start,
      );
      if (_trialStartWords.hasMatch(before)) continue;
      if (!_trialEndWords.hasMatch(before)) continue;
      if (d.date.isBefore(day)) continue;
      if (end == null || d.date.isBefore(end)) end = d.date;
    }
    if (end != null) return end;
    if (_trialEndsIn.firstMatch(sample) case final m?) {
      if (m[2] case final word?) {
        return word.toLowerCase() == 'today'
            ? day
            : day.add(const Duration(days: 1));
      }
      final days = _number(m[1]!);
      if (days != null && days <= 90) return day.add(Duration(days: days));
    }
    if (trialLengthIn(sample) case (:final count, :final unit)) {
      return switch (unit) {
        'day' when count <= 90 => day.add(Duration(days: count)),
        'week' when count <= 12 => day.add(Duration(days: 7 * count)),
        'month' when count <= 12 => DateTime.utc(
          day.year,
          day.month + count,
          day.day,
        ),
        'year' when count == 1 => DateTime.utc(
          day.year + 1,
          day.month,
          day.day,
        ),
        _ => null,
      };
    }
    return null;
  }
}
