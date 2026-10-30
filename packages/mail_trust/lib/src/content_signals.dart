// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

import 'brands.dart';
import 'domains.dart';
import 'free_mail.dart';

/// What a message's own words and recipients give away: who it claims to
/// speak for, whom it was sent to, and where its forms are. Used for scams
/// that come from real, verified addresses (often a hijacked account), so
/// sender checks pass.
abstract final class ContentSignals {
  // ----------------------------------------------------------- forms

  /// Free form services, by host: anyone can make a form there that asks
  /// for passwords, ID or payment details.
  static const _formHosts = {
    'forms.gle': 'Google Forms',
    'forms.office.com': 'Microsoft Forms',
    'forms.microsoft.com': 'Microsoft Forms',
    'forms.cloud.microsoft': 'Microsoft Forms',
    'typeform.com': 'Typeform',
    'jotform.com': 'Jotform',
    'surveymonkey.com': 'SurveyMonkey',
    'tally.so': 'Tally',
    'wufoo.com': 'Wufoo',
    'cognitoforms.com': 'Cognito Forms',
    'formstack.com': 'Formstack',
    'forms.zohopublic.com': 'Zoho Forms',
    'zfrmz.com': 'Zoho Forms',
    'formsite.com': 'Formsite',
  };

  /// The form service [link] opens, or null. Subdomains count
  /// (`yourname.typeform.com`); Google Docs only under `/forms`.
  static String? formService(Uri link) {
    if (link.scheme != 'http' && link.scheme != 'https') return null;
    final host = Domains.normalize(link.host);
    if (host == null) return null;
    if (host == 'docs.google.com' && link.path.startsWith('/forms')) {
      return 'Google Forms';
    }
    for (final MapEntry(key: service, value: name) in _formHosts.entries) {
      if (host == service || host.endsWith('.$service')) return name;
    }
    return null;
  }

  // ------------------------------------------------------- recipients

  /// Whether the message hides its recipients: a To with no address in it
  /// (`To: undisclosed-recipients:;`), or no To and Cc but a Bcc. Either
  /// way the reader got it as a blind copy among many.
  static bool hidesRecipients(MimeMessage message) {
    if (message.to.isNotEmpty || message.cc.isNotEmpty) return false;
    return message.headers.contains('to') || message.bcc.isNotEmpty;
  }

  // ---------------------------------------------------- organisations

  /// Parts of an address that don't name an organisation.
  static const _plainLabels = {
    'mail',
    'email',
    'mx',
    'www',
    'edu',
    'ac',
    'student',
    'students',
    'alumni',
    'staff',
    'my',
    'uni',
    'web',
    'online',
    'office',
    'connect',
    'live',
    'u',
  };

  /// Words that may sit inside an organisation's name without starting
  /// a word of its initials: "Institute *of* Technology".
  static const _joiners = {'of', 'and', 'for', 'the', '&', 'de', 'du', 'der'};

  /// The organisation [subject] names that one of [recipientHosts] belongs
  /// to (not a free mail service), e.g. "Singapore Institute of
  /// Technology" for `sit.singaporetech.edu.sg`, with that host.
  ///
  /// A name counts when its initials (SIT) or the whole word in capitals
  /// spell one of the address's labels, three letters or more.
  static ({String name, String host})? namedOrganisation(
    String? subject,
    Iterable<String> recipientHosts,
  ) {
    if (subject == null || subject.isEmpty) return null;
    final labels = <String, String>{}; // label -> host
    for (final host in recipientHosts) {
      final registrable = Domains.registrable(host);
      if (registrable == null || FreeMail.isProvider(registrable)) continue;
      final suffix = registrable.substring(registrable.indexOf('.') + 1);
      final named = host.substring(0, host.length - suffix.length - 1);
      for (final label in named.split('.')) {
        if (label.length >= 3 && !_plainLabels.contains(label)) {
          labels[label] = host;
        }
      }
    }
    if (labels.isEmpty) return null;
    for (final run in _capitalisedNames(subject)) {
      final all = run.split(' ');
      if (all.length == 1) {
        if (run == run.toUpperCase()) {
          if (labels[run.toLowerCase()] case final host?) {
            return (name: run, host: host);
          }
        }
        continue;
      }
      // Each name the run may end with: "Workshop for East Institute of
      // Technology" also tries "East Institute of Technology".
      for (var i = 0; i < all.length - 1; i++) {
        if (_joiners.contains(all[i].toLowerCase())) continue;
        final words = all.sublist(i);
        final initials = [
          for (final w in words)
            if (!_joiners.contains(w.toLowerCase())) w[0],
        ].join().toLowerCase();
        if (initials.length < 3) continue;
        if (labels[initials] case final host?) {
          return (name: words.join(' '), host: host);
        }
      }
    }
    return null;
  }

  /// Runs of capitalised words ("Singapore Institute of Technology"),
  /// joined by small words; also single words in capitals ("NUS").
  static Iterable<String> _capitalisedNames(String text) sync* {
    final words = text.split(RegExp(r'[^\p{L}\p{N}&]+', unicode: true));
    var run = <String>[];
    Iterable<String> finish() sync* {
      while (run.isNotEmpty && _joiners.contains(run.last.toLowerCase())) {
        run.removeLast();
      }
      if (run.isNotEmpty) yield run.join(' ');
      run = [];
    }

    for (final w in words) {
      if (w.isEmpty) continue;
      final capital = RegExp(r'^\p{Lu}', unicode: true).hasMatch(w);
      if (capital) {
        // Words in capitals ("STUDENT NOTICE") are names of their own.
        if (w.length > 1 && w == w.toUpperCase()) {
          yield* finish();
          yield w;
          continue;
        }
        run.add(w);
      } else if (run.isNotEmpty && _joiners.contains(w.toLowerCase())) {
        run.add(w);
      } else {
        yield* finish();
      }
    }
    yield* finish();
  }

  // ----------------------------------------------------------- brands

  /// Phrases that say a message speaks for, or with, someone.
  static final _onBehalf = RegExp(
    r'(?:partnership|partnered|collaboration|association|cooperation)\s+'
    r'(?:with|between)\s+([^.\n]{1,80})|on behalf of\s+([^.\n]{1,80})',
    caseSensitive: false,
  );

  /// A signature line that names a team or office.
  static final _signatureLine = RegExp(
    r'\b(?:Team|Division|Department|Partnerships?|Committee|Office|'
    r'Academy|Relations|Programs?|Programmes?)\b',
  );

  /// Distinctive brands the message writes in the name of, though
  /// [senderRegistrable] isn't theirs: in its subject, in a "partnership
  /// with" or "on behalf of" phrase, or in its closing lines (signature).
  static List<Brand> speaksFor(
    String? subject,
    String text,
    String senderRegistrable,
  ) {
    final closing = text.length > 600
        ? text.substring(text.length - 600)
        : text;
    final places = <String>[
      ?subject,
      for (final m in _onBehalf.allMatches(text)) m.group(1) ?? m.group(2)!,
      // Signature lines that name a team, not footers ("Get it on Google
      // Play").
      for (final line in closing.split('\n'))
        if (_signatureLine.hasMatch(line)) line,
    ];
    final found = <Brand>[];
    for (final brand in Brands.all) {
      if (!brand.distinctive || brand.owns(senderRegistrable)) continue;
      if (found.any((b) => b.name == brand.name)) continue;
      final word = RegExp(
        '(?<![\\p{L}\\p{N}])${RegExp.escape(brand.name)}(?![\\p{L}\\p{N}])',
        unicode: true,
      );
      if (places.any(word.hasMatch)) found.add(brand);
    }
    return found;
  }
}
