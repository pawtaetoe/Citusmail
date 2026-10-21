// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A date from a mail header: the instant plus the sender's UTC offset.
final class MailDate {
  const MailDate(this.utc, this.offset, {this.zoneKnown = true});

  /// The instant, in UTC.
  final DateTime utc;

  /// The sender's offset from UTC as written in the header.
  final Duration offset;

  /// False when the header had no usable time zone (then UTC was assumed).
  final bool zoneKnown;

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// Formats [instant] as an RFC 5322 date, e.g.
  /// `Wed, 21 Oct 2026 12:51:00 +0000`, at the given [offset].
  ///
  /// The default offset is UTC: writing the local offset would tell every
  /// recipient roughly where the sender is.
  static String format(DateTime instant, {Duration offset = Duration.zero}) {
    final t = instant.toUtc().add(offset);
    String two(int n) => n.toString().padLeft(2, '0');
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    return '${_days[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} ${t.year} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
        '$sign${two(minutes ~/ 60)}${two(minutes % 60)}';
  }

  @override
  String toString() => 'MailDate($utc, offset $offset)';
}

/// Parses RFC 5322 dates (section 3.3), including the obsolete forms and
/// the common mistakes real mailers make. Returns null if no date can be
/// read; never throws.
final class MailDateParser {
  const MailDateParser();

  static const _monthNames = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  /// Named zones from RFC 5322 4.3 (hours from UTC).
  static const _zones = {
    'ut': 0,
    'utc': 0,
    'gmt': 0,
    'z': 0,
    'est': -5,
    'edt': -4,
    'cst': -6,
    'cdt': -5,
    'mst': -7,
    'mdt': -6,
    'pst': -8,
    'pdt': -7,
  };

  static final _time = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$');
  static final _numericZone = RegExp(r'^([+-])(\d{2}):?(\d{2})$');

  MailDate? parse(String input) {
    if (input.length > 200) return null; // no real date is this long
    final text = _removeComments(input).replaceAll(',', ' ').trim();
    if (text.isEmpty) return null;
    return _parseRfc5322(text) ?? _parseIso8601(text);
  }

  MailDate? _parseRfc5322(String text) {
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    int? day, month, year, hour, minute, second;
    Duration? offset;
    var zoneKnown = false;

    for (final token in tokens) {
      final lower = token.toLowerCase();
      final timeMatch = _time.firstMatch(token);
      if (timeMatch != null && hour == null) {
        hour = int.parse(timeMatch.group(1)!);
        minute = int.parse(timeMatch.group(2)!);
        second = int.tryParse(timeMatch.group(3) ?? '0');
        continue;
      }
      final zoneMatch = _numericZone.firstMatch(token);
      if (zoneMatch != null && hour != null && offset == null) {
        final minutes =
            int.parse(zoneMatch.group(2)!) * 60 +
            int.parse(zoneMatch.group(3)!);
        offset = Duration(
          minutes: zoneMatch.group(1) == '-' ? -minutes : minutes,
        );
        // "-0000" means "zone unknown" (RFC 5322 3.3).
        zoneKnown = token != '-0000';
        continue;
      }
      if (_zones.containsKey(lower) && hour != null && offset == null) {
        offset = Duration(hours: _zones[lower]!);
        zoneKnown = true;
        continue;
      }
      if (lower.length >= 3 && month == null) {
        final index = _monthNames.indexOf(lower.substring(0, 3));
        if (index >= 0 && RegExp(r'^[a-z]+\.?$').hasMatch(lower)) {
          month = index + 1;
          continue;
        }
      }
      final number = int.tryParse(token);
      if (number != null) {
        if (day == null && token.length <= 2) {
          day = number;
        } else if (year == null && token.length >= 2 && token.length <= 4) {
          year = _fullYear(number, token.length);
        }
        continue;
      }
      // Day names, military zones and other words are ignored.
    }

    if (day == null ||
        month == null ||
        year == null ||
        hour == null ||
        minute == null) {
      return null;
    }
    second ??= 0;
    if (second == 60) second = 59; // leap second
    if (hour > 23 || minute > 59 || second > 59) return null;
    if (day < 1 || day > _daysInMonth(year, month)) return null;
    final effectiveOffset = offset ?? Duration.zero;
    if (effectiveOffset.inHours.abs() > 23) return null;
    final wall = DateTime.utc(year, month, day, hour, minute, second);
    return MailDate(
      wall.subtract(effectiveOffset),
      effectiveOffset,
      zoneKnown: offset != null && zoneKnown,
    );
  }

  MailDate? _parseIso8601(String text) {
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(text);
    final utc = hasZone
        ? parsed.toUtc()
        : DateTime.utc(
            parsed.year,
            parsed.month,
            parsed.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
          );
    return MailDate(utc, Duration.zero, zoneKnown: hasZone);
  }

  /// RFC 5322 4.3: two-digit years below 50 are 20xx; three digits add 1900.
  static int _fullYear(int year, int digits) => switch (digits) {
    2 => year < 50 ? 2000 + year : 1900 + year,
    3 => 1900 + year,
    _ => year,
  };

  static int _daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  static String _removeComments(String s) {
    final out = StringBuffer();
    var depth = 0;
    for (final char in s.split('')) {
      if (char == '(') {
        depth++;
      } else if (char == ')' && depth > 0) {
        depth--;
      } else if (depth == 0) {
        out.write(char);
      }
    }
    return out.toString();
  }
}
