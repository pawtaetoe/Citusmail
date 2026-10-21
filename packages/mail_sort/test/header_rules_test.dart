// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:test/test.dart';

final fixtureDir = Directory('../../test-data/mail');

/// What sync would hand the classifier for a fixture.
ClassificationInput fixture(String name, {SpecialUse? mailboxUse}) {
  final message = const MimeParser().parse(
    File('${fixtureDir.path}/$name').readAsBytesSync(),
  );
  final headers = <String, List<String>>{};
  for (final field in message.headers.fields) {
    headers.putIfAbsent(field.name.toLowerCase(), () => []).add(field.value);
  }
  return ClassificationInput(
    from: message.from.firstOrNull,
    headers: headers,
    mailboxUse: mailboxUse,
  );
}

ClassificationInput input({
  String from = 'someone@x.example',
  Map<String, List<String>> headers = const {},
  SpecialUse? mailboxUse,
}) {
  final at = from.lastIndexOf('@');
  return ClassificationInput(
    from: MailAddress(
      localPart: from.substring(0, at),
      domain: from.substring(at + 1),
    ),
    headers: headers,
    mailboxUse: mailboxUse,
  );
}

const classifier = HeaderRuleClassifier();

Matcher sortedAs(MessageCategory category, SortingReason reason) =>
    isA<Classification>()
        .having((c) => c.category, 'category', category)
        .having((c) => c.reason, 'reason', reason)
        .having((c) => c.source, 'source', CategorySource.rule);

void main() {
  group('every fixture lands where the plan says', () {
    const general = MessageCategory.general;
    const newsletters = MessageCategory.newsletters;
    const notifications = MessageCategory.notifications;

    final expected = <String, (MessageCategory, SortingReason)>{
      'notifications/github.eml': (notifications, SortingReason.knownService),
      'notifications/bank-alert.eml': (
        notifications,
        SortingReason.automatedSender,
      ),
      'notifications/delivery.eml': (
        notifications,
        SortingReason.automatedSender,
      ),
      'notifications/password-reset.eml': (
        notifications,
        SortingReason.automatedSender,
      ),
      'newsletters/one-click-unsubscribe.eml': (
        newsletters,
        SortingReason.oneClickUnsubscribe,
      ),
      // Sorting is not a trust decision: a failed DKIM check matters for
      // the unsubscribe button (M2), not for the folder.
      'newsletters/one-click-dkim-fail.eml': (
        newsletters,
        SortingReason.oneClickUnsubscribe,
      ),
      'newsletters/mailto-only-unsubscribe.eml': (
        newsletters,
        SortingReason.mailingList,
      ),
      'newsletters/web-link-only-unsubscribe.eml': (
        newsletters,
        SortingReason.mailingList,
      ),
      'newsletters/mailing-list-discussion.eml': (
        newsletters,
        SortingReason.mailingList,
      ),
      'newsletters/body-link-only.eml': (
        newsletters,
        SortingReason.bulkPrecedence,
      ),
      'receipts/mdn-displayed.eml': (general, SortingReason.noSignal),
    };
    for (final dir in ['people', 'security', 'malformed']) {
      for (final file in Directory('${fixtureDir.path}/$dir').listSync()) {
        expected['$dir/${file.uri.pathSegments.last}'] = (
          general,
          SortingReason.noSignal,
        );
      }
    }

    test('all fixtures are covered', () {
      final all = fixtureDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.eml'))
          .map((f) => f.path.substring(fixtureDir.path.length + 1))
          .where((p) => !p.startsWith('sent/') && !p.startsWith('drafts/'))
          .toSet();
      expect(expected.keys.toSet(), all);
    });

    for (final MapEntry(key: name, value: (category, reason))
        in expected.entries) {
      test(name, () {
        expect(classifier.classify(fixture(name)), sortedAs(category, reason));
      });
    }

    test('own mail in Sent and Drafts is General', () {
      expect(
        classifier.classify(
          fixture('sent/lunch-reply.eml', mailboxUse: SpecialUse.sent),
        ),
        sortedAs(general, SortingReason.ownMail),
      );
      expect(
        classifier.classify(
          fixture('drafts/unfinished.eml', mailboxUse: SpecialUse.drafts),
        ),
        sortedAs(general, SortingReason.ownMail),
      );
      // Even a newsletter saved to Drafts.
      expect(
        classifier
            .classify(
              fixture(
                'newsletters/one-click-unsubscribe.eml',
                mailboxUse: SpecialUse.drafts,
              ),
            )
            .category,
        general,
      );
    });
  });

  group('rule order', () {
    test(
      'a known service wins over list headers and one-click unsubscribe',
      () {
        expect(
          classifier.classify(
            input(
              from: 'notifications@github.com',
              headers: {
                'list-id': ['<repo.owner.github.com>'],
                'list-unsubscribe': ['<https://github.com/u>'],
                'list-unsubscribe-post': ['List-Unsubscribe=One-Click'],
                'precedence': ['bulk'],
              },
            ),
          ),
          sortedAs(MessageCategory.notifications, SortingReason.knownService),
        );
      },
    );

    test('one-click unsubscribe wins over a noreply sender', () {
      expect(
        classifier.classify(
          input(
            from: 'noreply@deals.example',
            headers: {
              'list-unsubscribe': ['<https://deals.example/u>'],
              'list-unsubscribe-post': ['  list-unsubscribe=ONE-CLICK '],
            },
          ),
        ),
        sortedAs(
          MessageCategory.newsletters,
          SortingReason.oneClickUnsubscribe,
        ),
      );
    });

    test('one-click needs both headers (RFC 8058)', () {
      expect(
        classifier.classify(
          input(
            headers: {
              'list-unsubscribe-post': ['List-Unsubscribe=One-Click'],
            },
          ),
        ),
        sortedAs(MessageCategory.general, SortingReason.noSignal),
      );
    });

    test('a noreply sender wins over plain list headers', () {
      expect(
        classifier.classify(
          input(
            from: 'no-reply@alerts.bank.example',
            headers: {
              'list-unsubscribe': ['<mailto:u@bank.example>'],
              'precedence': ['bulk'],
            },
          ),
        ),
        sortedAs(MessageCategory.notifications, SortingReason.automatedSender),
      );
    });

    test('auto-replies (out of office, bounces) stay in General', () {
      for (final value in [
        'auto-replied',
        'Auto-Replied; owner=x',
        'auto-replied (vacation)',
      ]) {
        expect(
          classifier.classify(
            input(
              from: 'noreply@x.example',
              headers: {
                'auto-submitted': [value],
                'precedence': ['bulk'],
              },
            ),
          ),
          sortedAs(MessageCategory.general, SortingReason.autoReply),
          reason: value,
        );
      }
    });

    test(
      'Auto-Submitted: auto-generated is a notification; "no" is nothing',
      () {
        expect(
          classifier.classify(
            input(
              headers: {
                'auto-submitted': ['auto-generated'],
              },
            ),
          ),
          sortedAs(
            MessageCategory.notifications,
            SortingReason.automatedSender,
          ),
        );
        expect(
          classifier
              .classify(
                input(
                  headers: {
                    'auto-submitted': ['auto-notified; owner-email="a@x"'],
                  },
                ),
              )
              .category,
          MessageCategory.notifications,
        );
        expect(
          classifier.classify(
            input(
              headers: {
                'auto-submitted': ['no'],
              },
            ),
          ),
          sortedAs(MessageCategory.general, SortingReason.noSignal),
        );
      },
    );

    test('Precedence values', () {
      for (final value in ['bulk', 'List', ' junk ', 'bulk (comment)']) {
        expect(
          classifier
              .classify(
                input(
                  headers: {
                    'precedence': [value],
                  },
                ),
              )
              .category,
          MessageCategory.newsletters,
          reason: value,
        );
      }
      for (final value in ['first-class', 'bulky', '']) {
        expect(
          classifier
              .classify(
                input(
                  headers: {
                    'precedence': [value],
                  },
                ),
              )
              .category,
          MessageCategory.general,
          reason: value,
        );
      }
    });

    test('empty or blank list headers are no signal', () {
      expect(
        classifier.classify(
          input(
            headers: {
              'list-id': [''],
              'list-unsubscribe': ['   '],
            },
          ),
        ),
        sortedAs(MessageCategory.general, SortingReason.noSignal),
      );
    });

    test('no sender at all is handled', () {
      expect(
        classifier.classify(const ClassificationInput(from: null, headers: {})),
        sortedAs(MessageCategory.general, SortingReason.noSignal),
      );
    });

    test('the rules version is positive and exposed', () {
      expect(classifier.version, HeaderRuleClassifier.currentVersion);
      expect(classifier.version, greaterThan(0));
    });
  });

  group('automated senders', () {
    bool automated(String local) => AutomatedSender.matches(
      MailAddress(localPart: local, domain: 'x.example'),
    );

    test('recognised', () {
      for (final local in [
        'noreply',
        'no-reply',
        'No_Reply',
        'no.reply',
        'do-not-reply',
        'donotreply',
        'DoNotReply+12345',
        'bank-alerts-noreply',
        'noreply-dmarc-support',
        'do_not_respond',
        'no-response',
        'notifications',
        'Notification',
        'notify',
        'alerts',
        'alert',
      ]) {
        expect(automated(local), isTrue, reason: local);
      }
    });

    test('people are not', () {
      for (final local in [
        'bob',
        'reply',
        'noel',
        'alertsteam',
        'notify.me.jane',
        'jane+noreply', // the tag is the user's own label
        '',
        '+noreply',
      ]) {
        expect(automated(local), isFalse, reason: local);
      }
    });
  });

  group('known services', () {
    String? service(String local, String domain) =>
        KnownServices.match(MailAddress(localPart: local, domain: domain))
            ?.name;

    test('match the domain and its subdomains, case-insensitively', () {
      expect(service('notifications', 'github.com'), 'GitHub');
      expect(service('Notifications', 'GitHub.COM'), 'GitHub');
      expect(service('gitlab', 'mg.gitlab.com'), 'GitLab');
      expect(service('jira', 'team.atlassian.net'), 'Jira');
    });

    test('never look-alikes or other senders at the domain', () {
      expect(service('notifications', 'evilgithub.com'), isNull);
      expect(service('notifications', 'github.com.evil.example'), isNull);
      expect(
        service('hello', 'github.com'),
        isNull,
      ); // not a notification sender
      // The Kelvin sign lower-cases to "k" in Unicode; it must not match.
      expect(service('notifications-noreply', 'bitbucKet.org'), isNull);
    });
  });

  group('List-Id', () {
    test('parsed and normalized', () {
      expect(
        ListId.parse('Project developers <dev.lists.Project.example>'),
        'dev.lists.project.example',
      );
      expect(
        ListId.parse('<readers.lists.club.example>'),
        'readers.lists.club.example',
      );
      expect(ListId.parse('  bare.example  '), 'bare.example');
      expect(
        ListId.parse('"a <b> c" <real.list.example>'),
        'real.list.example',
      );
      expect(
        ListId.parse('=?utf-8?q?Caf=C3=A9?= <cafe.list.example>'),
        'cafe.list.example',
      );
    });

    test('invalid ones are refused', () {
      for (final value in [
        null,
        '',
        '<>',
        '<nodot>',
        '<two words.example>',
        '<café.example>',
        '<Kelvin.example>',
        '<${'a' * 250}.example>',
        '<.leading.example>',
        '<a..b.example>',
      ]) {
        expect(ListId.parse(value), isNull, reason: value);
      }
    });

    test('the first valid List-Id of a message is used', () {
      expect(
        ListId.fromHeaders({
          'list-id': ['junk', '<good.list.example>', '<other.list.example>'],
        }),
        'good.list.example',
      );
      expect(ListId.fromHeaders(const {}), isNull);
    });
  });
}
