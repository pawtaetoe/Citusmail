// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// An evaluation of [MailModel] against the rules, on mail the trainer
/// never sees: the fixtures in test-data/mail, the sample of
/// mail_types_eval_test.dart and the hand-written held-out set. For each
/// kind: the rules alone (as the app runs them: subject words, then the
/// finder), the model alone above a threshold, and the rules or the
/// model. The table is printed (run with `--reporter expanded`) and
/// minimum numbers are pinned.
library;

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

import 'mail_model_heldout.dart';
import 'mail_types_eval_test.dart' as eval;

final _now = DateTime.utc(2026, 11, 27);

/// What each fixture is (the rest are none of them).
const _fixtureKinds = {
  'notifications/delivery.eml': MailKind.delivery,
  'notifications/password-reset.eml': MailKind.account,
};

final _tags = RegExp(r'<[^>]*>');
final _space = RegExp(r'[ \t]+');

List<Labelled> _fixtures() {
  final dir = Directory('../../test-data/mail');
  final out = <Labelled>[];
  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.eml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final name = file.path.substring(dir.path.length + 1);
    final m = const MimeParser().parse(file.readAsBytesSync());
    final from = m.from.firstOrNull;
    if (from == null) continue;
    final text =
        m.textBody?.decodeText().text ??
        (m.htmlBody?.decodeText().text ?? '')
            .replaceAll(_tags, ' ')
            .replaceAll(_space, ' ');
    out.add(
      Labelled(
        _fixtureKinds[name],
        from.address.toLowerCase(),
        from.displayName ?? '',
        m.subject ?? '',
        text,
        at: m.date?.utc ?? DateTime.utc(2026, 10, 1),
        bulk:
            m.headers.value('list-id') != null ||
            m.headers.value('list-unsubscribe') != null,
        source: 'fixture',
      ),
    );
  }
  return out;
}

/// The classifier evaluation labels only subscriptions, deliveries and
/// bookings: its haircuts and physio sessions ("not bookings") are
/// appointments.
const _evalAppointments = {'hello@snipstudio.com', 'appointments@movewell.com'};

List<Labelled> _eval() => [
  for (final m in eval.evaluationSample)
    Labelled(
      _evalAppointments.contains(m.sample.address)
          ? MailKind.appointment
          : m.kind,
      m.sample.address!,
      m.sample.senderName ?? '',
      m.sample.subject,
      m.sample.text,
      at: m.at,
      company: m.sample.domain,
      bulk: m.sample.bulk,
      reservations: m.reservations,
      source: 'eval',
    ),
];

const _kinds = MailKind.values;

bool _has(List<String> words, String subject) {
  final s = subject.toLowerCase();
  return words.any(s.contains);
}

/// What the rules find in [mail], as the app runs them: the emails of
/// every item found, per kind (indexes into [mail]).
Map<MailKind, Set<int>> _rules(List<Labelled> mail) {
  final indexed = [...mail.indexed];
  final subscriptions = SubscriptionFinder.find([
    for (final (i, m) in indexed)
      if (_has(SubscriptionFinder.subjectWords, m.subject))
        SubscriptionEmail(
          messageId: i,
          company: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
        ),
  ], now: _now);
  final deliveries = DeliveryFinder.find([
    for (final (i, m) in indexed)
      if (_has(DeliveryFinder.subjectWords, m.subject))
        DeliveryEmail(
          messageId: i,
          shop: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
          bulk: m.bulk,
        ),
  ], now: _now);
  final bookings = TripFinder.bookings([
    for (final (i, m) in indexed)
      if (_has(TripFinder.subjectWords, m.subject))
        TripEmail(
          messageId: i,
          sender: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
          reservations: m.reservations,
          bulk: m.bulk,
        ),
  ]);
  final appointments = AppointmentFinder.find([
    for (final (i, m) in indexed)
      if (_has(AppointmentFinder.subjectWords, m.subject))
        AppointmentEmail(
          messageId: i,
          sender: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
          reservations: m.reservations,
          bulk: m.bulk,
        ),
  ]);
  const free = {'gmail.com', 'outlook.com', 'gmx.at', 'web.de', 'icloud.com'};
  final accounts = AccountFinder.find([
    for (final (i, m) in indexed)
      if (_has([
        ...AccountFinder.subjectWords,
        ...SubscriptionFinder.subjectWords,
      ], m.subject))
        AccountEmail(
          messageId: i,
          company: m.company,
          senderName: m.name,
          subject: m.subject,
          text: m.text,
          at: m.at,
          fromPerson: free.contains(m.company),
          newsletter: m.bulk,
          code: VerificationCodes.isVerificationSubject(m.subject),
        ),
  ], now: _now);
  return {
    MailKind.subscription: {
      for (final s in subscriptions)
        for (final r in s.records) r.email.messageId,
    },
    MailKind.delivery: {
      for (final d in deliveries)
        for (final r in d.records) r.email.messageId,
    },
    MailKind.booking: {
      for (final b in bookings)
        for (final r in b.records) r.email.messageId,
    },
    MailKind.appointment: {
      for (final a in appointments)
        for (final r in a.records) r.email.messageId,
    },
    // A receipt shows an account too; here only account mail counts.
    MailKind.account: {
      for (final a in accounts)
        for (final r in a.records)
          if (r.evidence != AccountEvidence.paid) r.email.messageId,
    },
  };
}

typedef _Score = ({int tp, int fp, int fn, double precision, double recall});

_Score _score(List<Labelled> mail, Set<int> picked, MailKind kind) {
  final truth = {
    for (final (i, m) in mail.indexed)
      if (m.kind == kind) i,
  };
  final tp = picked.intersection(truth).length;
  final fp = picked.difference(truth).length;
  final fn = truth.difference(picked).length;
  return (
    tp: tp,
    fp: fp,
    fn: fn,
    precision: tp + fp == 0 ? 1 : tp / (tp + fp),
    recall: tp + fn == 0 ? 1 : tp / (tp + fn),
  );
}

String _cell(_Score s) =>
    'P ${s.precision.toStringAsFixed(2)} R ${s.recall.toStringAsFixed(2)} '
    '(${s.tp}/${s.fp}/${s.fn})';

void main() {
  final mail = [..._fixtures(), ..._eval(), ...heldOut];
  final model = MailModel.standard;
  final predictions = [for (final m in mail) model.classify(m.sample)];
  final rules = _rules(mail);

  Set<int> byModel(MailKind kind, double threshold) => {
    for (final (i, p) in predictions.indexed)
      if (p.of(kind) >= threshold) i,
  };

  test('the held-out mail', () {
    expect(mail.where((m) => m.source == 'fixture').length, greaterThan(30));
    expect(mail.where((m) => m.source == 'eval').length, greaterThan(40));
    expect(heldOut.length, greaterThan(60));
  });

  test('evaluation: rules, model, rules or model', () {
    final out = StringBuffer()
      ..writeln(
        'Held-out mail: ${mail.length} emails (fixtures, the classifier '
        'evaluation, the held-out set). P precision, R recall '
        '(right/wrong/missed).',
      );
    for (final kind in _kinds) {
      final threshold = MailModel.thresholds[kind]!;
      final picked = rules[kind]!;
      final sure = byModel(kind, threshold);
      // What the model is sure is not a [kind].
      final not = {
        for (final (i, p) in predictions.indexed)
          if (p.of(kind) < 0.1) i,
      };
      out
        ..writeln(kind.name)
        ..writeln(
          '  rules                 ${_cell(_score(mail, picked, kind))}',
        );
      for (final t in {0.5, 0.7, threshold, 0.9}.toList()..sort()) {
        out.writeln(
          '  model >= ${t.toStringAsFixed(2)}         '
          '${_cell(_score(mail, byModel(kind, t), kind))}',
        );
      }
      out
        ..writeln(
          '  rules or model >= ${threshold.toStringAsFixed(2)} '
          '${_cell(_score(mail, picked.union(sure), kind))}',
        )
        ..writeln(
          '  rules unless < 0.10   '
          '${_cell(_score(mail, picked.difference(not), kind))}',
        );
      final truth = {
        for (final (i, m) in mail.indexed)
          if (m.kind == kind) i,
      };
      for (final i in sure.difference(truth)) {
        out.writeln('    model wrong: ${mail[i].subject} (${predictions[i]})');
      }
      for (final i in truth.difference(picked).difference(sure)) {
        out.writeln('    both miss: ${mail[i].subject} (${predictions[i]})');
      }
    }
    final b = MailKind.booking;
    out.writeln('Bookings the rules miss and the model finds:');
    for (final (i, m) in mail.indexed) {
      if (m.kind == b &&
          !rules[b]!.contains(i) &&
          predictions[i].of(b) >= MailModel.thresholds[b]!) {
        out.writeln('  + ${m.subject}');
      }
    }
    // ignore: avoid_print
    print(out);

    for (final kind in _kinds) {
      final threshold = MailModel.thresholds[kind]!;
      final r = _score(mail, rules[kind]!, kind);
      final m = _score(mail, byModel(kind, threshold), kind);
      final u = _score(
        mail,
        rules[kind]!.union(byModel(kind, threshold)),
        kind,
      );
      // The model alone is right nearly always, and finds most.
      expect(m.precision, greaterThanOrEqualTo(0.95), reason: kind.name);
      expect(m.recall, greaterThanOrEqualTo(0.8), reason: kind.name);
      // With the rules, it never finds less than they do alone.
      expect(u.recall, greaterThanOrEqualTo(r.recall), reason: kind.name);
    }
    // Bookings, where the rules miss most: the model adds them, and
    // brings few wrong ones.
    final rb = _score(mail, rules[b]!, b);
    final ub = _score(
      mail,
      rules[b]!.union(byModel(b, MailModel.thresholds[b]!)),
      b,
    );
    expect(rb.recall, lessThan(0.5));
    expect(ub.recall, greaterThanOrEqualTo(0.95));
    expect(ub.precision, greaterThanOrEqualTo(0.9));
  });

  test('the type of booking', () {
    final typed = [
      for (final (i, m) in mail.indexed)
        if (m.type != null) (m, predictions[i]),
    ];
    final right = typed.where((t) => t.$2.bookingType == t.$1.type).length;
    // ignore: avoid_print
    print('Booking type right: $right of ${typed.length}');
    expect(right / typed.length, greaterThanOrEqualTo(0.9));
  });
}
