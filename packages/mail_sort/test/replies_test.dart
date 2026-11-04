// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:test/test.dart';

MailAddress _address(String a, [String? name]) => MailAddress(
  displayName: name,
  localPart: a.split('@').first,
  domain: a.split('@').last,
);

const _me = 'tan.wei@citusmail.test';

/// Tan asked a builder for a quote, as a new conversation.
final _quote = AwaitedMessage(
  messageId: 'CAF7q1x0quote.kitchen@citusmail.test',
  recipients: ['ana@buildright.example', 'Office@BuildRight.example'],
);

/// Tan's answer, deep in a thread with a landlord.
final _lease = AwaitedMessage(
  messageId: 'lease-renewal-3@citusmail.test',
  inReplyTo: 'msg-2.8812@lettings.example',
  references: ['msg-1.8810@lettings.example', 'msg-2.8812@lettings.example'],
  recipients: ['priya@lettings.example'],
);

ReplyCandidate _mail({
  String? id,
  String? inReplyTo,
  List<String> references = const [],
  required String from,
  String? name,
  String? subject,
  Map<String, List<String>> headers = const {},
}) => ReplyCandidate(
  messageId: id,
  inReplyTo: inReplyTo,
  references: references,
  from: _address(from, name),
  subject: subject,
  headers: headers,
);

bool _answers(ReplyCandidate m, AwaitedMessage sent) =>
    Replies.answers(m, sent, ownAddresses: {_me, 'tan@old-isp.example'});

void main() {
  group('a reply', () {
    test('names the message in In-Reply-To', () {
      final reply = _mail(
        id: 'BY5PR11MB4136@buildright.example',
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        references: ['CAF7q1x0quote.kitchen@citusmail.test'],
        from: 'ana@buildright.example',
        name: 'Ana Costa',
        subject: 'RE: Quote for the kitchen',
      );
      expect(_answers(reply, _quote), isTrue);
    });

    test('names it only in References (an answer to a later message)', () {
      final reply = _mail(
        id: 'office-77@buildright.example',
        inReplyTo: 'BY5PR11MB4136@buildright.example',
        references: [
          '<CAF7q1x0quote.kitchen@citusmail.test>',
          '<BY5PR11MB4136@buildright.example>',
        ],
        from: 'office@buildright.example',
        subject: 'Re: Quote for the kitchen',
      );
      expect(_answers(reply, _quote), isTrue);
    });

    test('from someone it was not sent to, still in reply to it', () {
      // Ana passed it on to a colleague, who answered it.
      final reply = _mail(
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        from: 'marco@buildright.example',
        subject: 'Re: Quote for the kitchen',
      );
      expect(_answers(reply, _quote), isTrue);
    });

    test('continues the same conversation, from someone it went to', () {
      // Priya answered the landlord's earlier message, not Tan's.
      final reply = _mail(
        inReplyTo: 'msg-1.8810@lettings.example',
        references: ['msg-1.8810@lettings.example'],
        from: 'Priya@Lettings.example',
        subject: 'Re: Your lease renewal',
      );
      expect(_answers(reply, _lease), isTrue);
    });

    test('auto-submitted "no" is a person', () {
      final reply = _mail(
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        from: 'ana@buildright.example',
        subject: 'Re: Quote for the kitchen',
        headers: {
          'auto-submitted': ['no'],
        },
      );
      expect(_answers(reply, _quote), isTrue);
    });
  });

  group('not a reply', () {
    test('from yourself (a nudge, or a copy to yourself)', () {
      final nudge = _mail(
        id: 'nudge@citusmail.test',
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        references: ['CAF7q1x0quote.kitchen@citusmail.test'],
        from: 'Tan.Wei@citusmail.test',
        name: 'Tan Wei',
        subject: 'Re: Quote for the kitchen',
      );
      expect(_answers(nudge, _quote), isFalse);
      final otherAccount = _mail(
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        from: 'tan@old-isp.example',
        subject: 'Re: Quote for the kitchen',
      );
      expect(_answers(otherAccount, _quote), isFalse);
    });

    test('an out-of-office reply (Auto-Submitted)', () {
      final away = _mail(
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        references: ['CAF7q1x0quote.kitchen@citusmail.test'],
        from: 'ana@buildright.example',
        name: 'Ana Costa',
        subject: 'Automatic reply: Quote for the kitchen',
        headers: {
          'auto-submitted': ['auto-replied'],
        },
      );
      expect(_answers(away, _quote), isFalse);
    });

    test('an out-of-office without headers, by its subject', () {
      for (final subject in [
        'Out of Office: Quote for the kitchen',
        'Out of office until 12 November',
        'Automatic reply: Quote for the kitchen',
        'Auto-Reply: Quote for the kitchen',
        'Autoreply: I am away',
        'Abwesenheitsnotiz: Quote for the kitchen',
        'Réponse automatique : Quote for the kitchen',
        'Respuesta automática: Quote for the kitchen',
      ]) {
        final away = _mail(
          inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
          from: 'ana@buildright.example',
          subject: subject,
        );
        expect(_answers(away, _quote), isFalse, reason: subject);
      }
    });

    test('older auto-reply headers', () {
      for (final headers in [
        {
          'x-autoreply': ['yes'],
        },
        {
          'x-autorespond': ['Out of the office'],
        },
        {
          'precedence': ['auto_reply'],
        },
        {
          'auto-submitted': ['auto-generated'],
        },
      ]) {
        final away = _mail(
          inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
          from: 'ana@buildright.example',
          subject: 'Re: Quote for the kitchen',
          headers: headers,
        );
        expect(_answers(away, _quote), isFalse, reason: '$headers');
      }
    });

    test('a bounce or a read receipt', () {
      final bounce = _mail(
        references: ['CAF7q1x0quote.kitchen@citusmail.test'],
        from: 'MAILER-DAEMON@mx.buildright.example',
        subject: 'Undelivered Mail Returned to Sender',
      );
      expect(_answers(bounce, _quote), isFalse);
      final receipt = _mail(
        inReplyTo: 'CAF7q1x0quote.kitchen@citusmail.test',
        from: 'ana@buildright.example',
        subject: 'Read: Quote for the kitchen',
        headers: {
          'content-type': [
            ('multipart/report; report-type=disposition-notification; '
                'boundary="b1"'),
          ],
        },
      );
      expect(_answers(receipt, _quote), isFalse);
    });

    test('the same person writing about something else', () {
      // Ana starts a new conversation the next day.
      final other = _mail(
        id: 'invoice-0041@buildright.example',
        from: 'ana@buildright.example',
        name: 'Ana Costa',
        subject: 'Invoice 0041 for the bathroom tiles',
      );
      expect(_answers(other, _quote), isFalse);
      // ...or answers an older, different conversation.
      final older = _mail(
        inReplyTo: 'bathroom-tiles@citusmail.test',
        references: ['bathroom-tiles@citusmail.test'],
        from: 'ana@buildright.example',
        subject: 'Re: Bathroom tiles',
      );
      expect(_answers(older, _quote), isFalse);
    });

    test('a mailing list quoting the subject', () {
      final digest = _mail(
        id: 'digest-1182@lists.diy.example',
        from: 'renovators@lists.diy.example',
        name: 'Renovators Digest',
        subject: 'Re: Quote for the kitchen - is 9k too much?',
        headers: {
          'list-id': ['Renovators <renovators.lists.diy.example>'],
          'precedence': ['list'],
        },
      );
      expect(_answers(digest, _quote), isFalse);
    });

    test('someone else in the same conversation who was not asked', () {
      // A letting agent's colleague answers the landlord's first message:
      // the same thread, but Tan's message didn't go to them.
      final colleague = _mail(
        inReplyTo: 'msg-1.8810@lettings.example',
        references: ['msg-1.8810@lettings.example'],
        from: 'accounts@lettings.example',
        subject: 'Re: Your lease renewal',
      );
      expect(_answers(colleague, _lease), isFalse);
    });

    test('the sent message itself', () {
      final copy = _mail(
        id: 'CAF7q1x0quote.kitchen@citusmail.test',
        from: 'someone@else.example',
      );
      expect(_answers(copy, _quote), isFalse);
    });
  });

  test('thread roots', () {
    expect(_quote.threadRoot, 'CAF7q1x0quote.kitchen@citusmail.test');
    expect(_lease.threadRoot, 'msg-1.8810@lettings.example');
    expect(
      Replies.threadRoot(inReplyTo: '<a@x.example>', references: const []),
      'a@x.example',
    );
    expect(Replies.threadRoot(), isNull);
  });
}
