// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// The synthetic mail [MailModel] is trained on: made-up emails in the
/// layouts and languages of many kinds of real senders, never anyone's
/// real mail. The same seed always gives the same emails.
library;

import 'package:mail_sort/mail_sort.dart';

import 'rng.dart';
import 'synthetic_other.dart';
import 'synthetic_parts.dart';
import 'synthetic_travel.dart';

/// One made-up email and what it is.
final class SynthMail {
  const SynthMail(this.label, this.sample, {this.template = ''});

  final MailClass label;
  final MailSample sample;

  /// Which template made it.
  final String template;
}

typedef Template = SynthMail Function(Rng r);

/// An email from [sender].
SynthMail synth(
  MailClass label,
  Sender sender,
  String subject,
  String text, {
  bool bulk = false,
}) => SynthMail(
  label,
  MailSample(
    address: sender.address,
    domain: sender.domain,
    senderName: sender.name,
    subject: subject,
    text: text,
    bulk: bulk,
  ),
);

/// The seed the shipped model was trained with.
const trainingSeed = 20261127;

/// How many emails of each class to make, about.
const perClass = 520;

/// Every template, by class.
List<Template> get allTemplates => [...travelTemplates, ...otherTemplates];

/// The training mail: about [perClass] emails of each class, from each
/// class's templates in turn, with noise. Deterministic for [seed].
List<SynthMail> syntheticMail({
  int seed = trainingSeed,
  int perClass = perClass,
}) {
  final r = Rng(seed);
  // Which class each template makes, from one sample of it.
  final byClass = <MailClass, List<(int, Template)>>{};
  for (final (i, t) in allTemplates.indexed) {
    final label = t(Rng(seed ^ (i * 7919))).label;
    byClass.putIfAbsent(label, () => []).add((i, t));
  }
  final out = <SynthMail>[];
  for (final c in MailClass.values) {
    final templates = byClass[c] ?? const [];
    if (templates.isEmpty) continue;
    final each = (perClass / templates.length).ceil();
    for (final (i, t) in templates) {
      for (var n = 0; n < each; n++) {
        final m = t(r);
        out.add(SynthMail(m.label, _noise(r, m.sample), template: 't$i'));
      }
    }
  }
  return out;
}

/// What happens to mail on the way: upper-case subjects, emoji, tags,
/// sender names missing.
MailSample _noise(Rng r, MailSample s) {
  var subject = s.subject;
  if (r.chance(0.04)) subject = subject.toUpperCase();
  if (r.chance(0.05)) {
    subject = '${r.pick(['✈️', '🎟️', '📦', '✅', '🚆', '🏨'])} $subject';
  }
  if (r.chance(0.03)) subject = '[External] $subject';
  return MailSample(
    address: s.address,
    domain: s.domain,
    senderName: r.chance(0.08) ? null : s.senderName,
    subject: subject,
    text: s.text,
    bulk: s.bulk,
  );
}
