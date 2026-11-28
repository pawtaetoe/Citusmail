// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A forwarded email as its first sender wrote it: who sent it, when,
/// its subject and its words, without the forwarder's note.
final class ForwardedMail {
  const ForwardedMail({
    required this.subject,
    required this.text,
    this.senderName,
    this.address,
    this.sent,
    this.to,
  });

  /// The first sender's display name, if the forward gives one.
  final String? senderName;

  /// The first sender's address (`reservations@example-inn.com`), lower
  /// case, if the forward gives one.
  final String? address;

  /// When it was first sent, if the forward says.
  final DateTime? sent;

  /// The first recipient's address, lower case, if the forward gives one.
  final String? to;
  final String subject;

  /// Its words, from after the forward's header block.
  final String text;

  /// The registrable domain of [address] (`example-inn.com` for
  /// `mail.example-inn.com`), or null.
  String? get domain => switch (address) {
    final a? => Forwards.registrableOf(a.substring(a.lastIndexOf('@') + 1)),
    null => null,
  };
}

/// Tells replies from forwards and reads what a forward forwards: the
/// header block Outlook ("From: … Sent: … To: … Subject: …"), Gmail
/// ("---------- Forwarded message ---------") and Apple Mail ("Begin
/// forwarded message:") put above the original, by a person or by a
/// mailbox rule.
abstract final class Forwards {
  static RegExp _re(String p) => RegExp(p, caseSensitive: false);

  /// "Re:", "AW:", "SV:": an answer (in English, German, Nordic...).
  static final _replyPrefix = _re(
    r'^\s*(?:\[[^\]]*\]\s*)?(?:re|aw|sv|vs|odp|antw)\s*(?:\[\d+\])?\s*:',
  );

  /// "Fw:", "Fwd:", "WG:", "TR:", "RV:", "Doorst:": a forward, maybe of a
  /// forward ("Fwd: FW: ...").
  static final _forwardPrefix = _re(
    r'^\s*(?:\[[^\]]*\]\s*)?(?:(?:fwd?|wg|tr|rv|doorst|enc)\s*(?:\[\d+\])?\s*:\s*)+',
  );

  /// Whether [subject] is a reply ("Re: ...").
  static bool isReply(String subject) => _replyPrefix.hasMatch(subject);

  /// Whether [subject] is a forward ("Fw: ...", "Fwd: ...").
  static bool isForward(String subject) =>
      !isReply(subject) && _forwardPrefix.hasMatch(subject);

  /// [self] as its first sender wrote it: itself when [subject] is
  /// neither a reply nor a forward; for a forward, [rebuild] of what it
  /// forwards; null for a reply, a forward of one, or a forward whose
  /// original cannot be read. [at] is when [self] arrived: a sent date
  /// read after it, or long before, is not believed.
  static T? originalOf<T>(
    T self, {
    required String subject,
    required String text,
    required DateTime at,
    required T Function(ForwardedMail original, DateTime sent) rebuild,
  }) {
    if (isReply(subject)) return null;
    if (!isForward(subject)) return self;
    final f = unwrap(subject, text);
    if (f == null || isReply(f.subject)) return null;
    final sent = f.sent;
    final believable =
        sent != null &&
        !sent.isAfter(at.add(const Duration(days: 1))) &&
        sent.isAfter(at.subtract(const Duration(days: 800)));
    return rebuild(f, believable ? sent : at);
  }

  /// [subject] without its forward prefixes ("Fw: Fwd: X" is "X").
  static String withoutPrefix(String subject) =>
      subject.replaceFirst(_forwardPrefix, '').trim();

  /// Labels of a forward's header lines, in the languages mail programs
  /// write them in.
  static const _fromLabels = r'from|von|de|da|van|från|fra|od';
  static const _otherLabels =
      r'sent|date|to|cc|bcc|subject|reply-to|importance|attachments|'
      r'gesendet|datum|an|betreff|envoyé|date d.envoi|à|objet|enviado|fecha|'
      r'para|asunto|inviato|oggetto|a|verzonden|aan|onderwerp|skickat|till|'
      r'ämne|sendt|til|emne';

  /// What starts a forward's header block, when there is a line: the
  /// forwarder's rule, or the program's words.
  static final _separator = _re(
    r'(?:_{8,}|-{5,}\s*(?:forwarded message|original message|'
    r'weitergeleitete nachricht|ursprüngliche nachricht|message transféré|'
    r'mensaje reenviado|messaggio inoltrato)\s*-{5,}|'
    r'begin forwarded message:|anfang der weitergeleiteten nachricht:)',
  );

  /// "From: Name <address>" at the start of a header block.
  static final _from = _re('(?:^|(?<=[\\s>]))(?:$_fromLabels)\\s*:[ \\t]*');

  /// Any header label of the block, the value after it.
  static final _label = _re(
    '(?:^|(?<=[\\s>]))($_fromLabels|$_otherLabels)\\s*:[ \\t]*',
  );

  static final _subjectLabel = _re(
    r'^(?:subject|betreff|objet|asunto|oggetto|onderwerp|ämne|emne)$',
  );
  static final _dateLabel = _re(
    r'^(?:sent|date|gesendet|datum|envoyé|date d.envoi|enviado|fecha|inviato|'
    r'verzonden|skickat|sendt)$',
  );
  static final _toLabel = _re(r'^(?:to|an|à|para|a|aan|till|til)$');

  static final _address = RegExp(
    r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',
  );

  /// A banner a mail gateway puts at the top ("CAUTION: This email
  /// originated from outside of the organisation...").
  static final _banner = _re(
    r'^\s*(?:\[?(?:caution|warning|external(?: email| sender)?|attention)\]?'
    r'\s*[:!-][^\n]{0,400}(?:\n|$))+',
  );

  /// How far into the text the header block may start.
  static const _reach = 4000;

  /// The email [subject] and [text] forward, or null: [subject] must say
  /// it is a forward, and [text] must hold the header block with the
  /// original's sender or subject. A forward of a forward is unwrapped
  /// to the first.
  static ForwardedMail? unwrap(String subject, String text) {
    if (!isForward(subject)) return null;
    ForwardedMail? found;
    var s = subject;
    var t = text;
    // A forward of a forward: the innermost one wrote it.
    for (var depth = 0; depth < 3; depth++) {
      final next = _unwrapOnce(withoutPrefix(s), t);
      if (next == null) break;
      found = next;
      if (!isForward(next.subject)) break;
      s = next.subject;
      t = next.text;
    }
    return found;
  }

  static ForwardedMail? _unwrapOnce(String bareSubject, String text) {
    final sample = text.length > _reach + 1500
        ? text.substring(0, _reach + 1500)
        : text;
    final separator = _separator.firstMatch(sample);
    // The header block: after the separator line, else the first
    // "From:" (an Outlook forward may have none).
    final searchFrom = separator != null && separator.start < _reach
        ? separator.end
        : 0;
    final from = _from.allMatches(sample, searchFrom).firstOrNull;
    if (from == null || from.start > _reach) return null;
    // Its labels, one after another; the block ends at the first line
    // that is not one, or after the subject when it is all on one line.
    final multiLine = sample.substring(from.start).contains('\n');
    final fields = <String, String>{};
    var end = from.start;
    if (multiLine) {
      var at = from.start;
      while (at < sample.length) {
        var lineEnd = sample.indexOf('\n', at);
        if (lineEnd < 0) lineEnd = sample.length;
        final line = sample.substring(at, lineEnd);
        final m = _label.matchAsPrefix(line.trimLeft());
        if (m == null) {
          if (fields.isEmpty) return null;
          if (line.trim().isEmpty && !fields.keys.any(_subjectLabel.hasMatch)) {
            // A blank line inside the block (Outlook wraps "To:").
            at = lineEnd + 1;
            continue;
          }
          break;
        }
        final key = m[1]!.toLowerCase();
        fields.putIfAbsent(key, () => line.trimLeft().substring(m.end).trim());
        end = lineEnd;
        at = lineEnd + 1;
      }
    } else {
      final labels = _label.allMatches(sample, from.start).toList();
      for (final (i, m) in labels.indexed) {
        if (i > 0 && m.start - labels[i - 1].end > 300) break;
        final key = m[1]!.toLowerCase();
        final valueEnd = i + 1 < labels.length
            ? labels[i + 1].start
            : sample.length;
        var value = sample.substring(m.end, valueEnd).trim();
        if (_subjectLabel.hasMatch(key)) {
          // The subject runs into the body: it is the forward's own,
          // without the prefix, when that fits.
          if (value.toLowerCase().startsWith(bareSubject.toLowerCase()) &&
              bareSubject.isNotEmpty) {
            value = value.substring(0, bareSubject.length);
            end = m.end + value.length;
            fields.putIfAbsent(key, () => value);
            break;
          }
          if (i + 1 >= labels.length) {
            value = bareSubject;
            end = m.end;
            fields.putIfAbsent(key, () => value);
            break;
          }
        }
        fields.putIfAbsent(key, () => value);
        end = valueEnd;
      }
    }
    String? field(RegExp label) {
      for (final MapEntry(:key, :value) in fields.entries) {
        if (label.hasMatch(key)) return value;
      }
      return null;
    }

    final fromValue = fields.entries.first.value;
    final subjectValue = field(_subjectLabel);
    final dateValue = field(_dateLabel);
    // A block names its sender and either its subject or its date: not
    // "From: London" in a train ticket.
    if (subjectValue == null && dateValue == null) return null;
    final address = _address.firstMatch(fromValue)?[0]?.toLowerCase();
    var name = fromValue
        .replaceAll(_address, '')
        .replaceAll(RegExp(r'\[mailto:\s*\]|<\s*>|\(\s*\)|\[\s*\]'), '')
        .replaceAll(RegExp(r'''^[\s"'<]+|[\s"'>,;]+$'''), '')
        .trim();
    if (name.isEmpty || name.contains('@')) name = '';
    final toValue = field(_toLabel);
    var body = end < text.length ? text.substring(end) : '';
    body = body.replaceFirst(RegExp(r'^[\s>]+'), '').replaceFirst(_banner, '');
    return ForwardedMail(
      senderName: name.isEmpty ? null : name,
      address: address,
      sent: dateValue == null ? null : sentAt(dateValue),
      to: toValue == null
          ? null
          : _address.firstMatch(toValue)?[0]?.toLowerCase(),
      subject: (subjectValue == null || subjectValue.isEmpty)
          ? bareSubject
          : subjectValue,
      text: body.trim(),
    );
  }

  // ------------------------------------------------------------ the date

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
      r'(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?';
  static final _dayMonthYear = _re(
    '\\b(\\d{1,2})(?:st|nd|rd|th)?\\.?\\s+$_month,?\\s+(\\d{4})\\b',
  );
  static final _monthDayYear = _re(
    '\\b$_month\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b',
  );
  static final _isoDate = RegExp(r'\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b');
  static final _clock = _re(
    r'\b(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\s*([ap])?\.?\s?m?\b',
  );
  static final _offset = _re(
    r'(?:\(?(?:utc|gmt)\s*([+-])(\d{1,2}):?(\d{2})?\)?|(?<![\d:])([+-])(\d{2})(\d{2})\b)',
  );

  /// When a forward's "Sent:" or "Date:" line says it was sent:
  /// "Tuesday, June 9, 2026 7:41 PM", "Tuesday, 3 March 2026 10:12:44 am
  /// (UTC+01:00) Amsterdam, Berlin", "Tue, 9 Jun 2026, 9:00 am".
  /// UTC when an offset is given, else the device's time; null when no
  /// date is written.
  static DateTime? sentAt(String value) {
    int? y, mo, d;
    var rest = value;
    if (_dayMonthYear.firstMatch(value) case final m?) {
      (y, mo, d) = (
        int.parse(m[3]!),
        _months[m[2]!.toLowerCase().substring(0, 3)],
        int.parse(m[1]!),
      );
      rest = value.substring(m.end);
    } else if (_monthDayYear.firstMatch(value) case final m?) {
      (y, mo, d) = (
        int.parse(m[3]!),
        _months[m[1]!.toLowerCase().substring(0, 3)],
        int.parse(m[2]!),
      );
      rest = value.substring(m.end);
    } else if (_isoDate.firstMatch(value) case final m?) {
      (y, mo, d) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      rest = value.substring(m.end);
    }
    if (y == null || mo == null || d == null || mo < 1 || mo > 12) return null;
    var hour = 0, minute = 0;
    if (_clock.firstMatch(rest) case final c?) {
      final h = int.parse(c[1]!);
      final ampm = c[3]?.toLowerCase();
      if (ampm == null) {
        if (h < 24) hour = h;
      } else if (h >= 1 && h <= 12) {
        hour = h % 12 + (ampm == 'p' ? 12 : 0);
      }
      minute = int.parse(c[2]!).clamp(0, 59);
      rest = rest.substring(c.end);
    }
    if (_offset.firstMatch(rest) case final o?) {
      final sign = (o[1] ?? o[4]) == '-' ? -1 : 1;
      final oh = int.parse(o[2] ?? o[5]!);
      final om = int.parse(o[3] ?? o[6] ?? '0');
      return DateTime.utc(
        y,
        mo,
        d,
        hour,
        minute,
      ).subtract(Duration(minutes: sign * (oh * 60 + om)));
    }
    return DateTime(y, mo, d, hour, minute);
  }

  // ---------------------------------------------------------- the domain

  /// Second-level labels under a country's ending that are not a
  /// company's name (`co` in `example.co.uk`).
  static const _secondLevel = {
    'co',
    'com',
    'ac',
    'org',
    'net',
    'gov',
    'edu',
    'ne',
    'or',
    'go',
    'gob',
    'nic',
    'mil',
    'sch',
    'ltd',
    'plc',
  };

  /// The registrable domain of [host], roughly: its last two labels, or
  /// three under a country's ending with a second level such as `co.uk`
  /// or `edu.sg`.
  static String registrableOf(String host) {
    final labels = host
        .toLowerCase()
        .split('.')
        .where((l) => l.isNotEmpty)
        .toList();
    if (labels.length <= 2) return labels.join('.');
    final n = labels.length;
    final take =
        labels[n - 1].length == 2 && _secondLevel.contains(labels[n - 2])
        ? 3
        : 2;
    return labels.sublist(n - take).join('.');
  }
}
