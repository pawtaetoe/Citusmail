// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'draft.dart';

/// Answers to meeting invitations: a short email to the organizer only,
/// "Accepted: Q4 roadmap review", carrying the iTIP REPLY their calendar
/// reads. Sent like any message (the outbox, with undo), from the account
/// the invitation came to.
abstract final class InvitationReplies {
  /// The answer to [invite] (received in [message]) as [attendee], the
  /// user's own ATTENDEE in it. [answer] is accepted, tentative or
  /// declined; [note] an optional message for the organizer. Null when
  /// the invitation can't be answered (no organizer address).
  static Draft? draft({
    required StoredMessage message,
    required Account account,
    required CalendarInvite invite,
    required CalendarPerson attendee,
    required CalendarAnswer answer,
    String? note,
    DateTime? now,
  }) {
    final organizer = invite.organizer;
    final email = organizer?.email;
    if (organizer == null || email == null || !invite.answerable) return null;
    final at = email.lastIndexOf('@');
    final to = MailAddress(
      displayName: organizer.name,
      localPart: email.substring(0, at),
      domain: email.substring(at + 1),
    );
    final title = invite.summary ?? 'Invitation';
    final name = account.displayName?.trim().isNotEmpty == true
        ? account.displayName!.trim()
        : attendee.name ?? attendee.email ?? account.email;
    final cleanNote = note?.trim();
    final body = StringBuffer(switch (answer) {
      CalendarAnswer.accepted => '$name has accepted this invitation.',
      CalendarAnswer.tentative => '$name might attend (tentative).',
      CalendarAnswer.declined => '$name has declined this invitation.',
      _ => throw ArgumentError.value(answer, 'answer', 'not an answer'),
    });
    if (cleanNote != null && cleanNote.isNotEmpty) {
      body.write('\n\n$cleanNote');
    }
    final messageId = message.messageId;
    return Draft(
      accountId: account.id,
      to: [to],
      subject: '${subjectPrefix(answer)} $title',
      body: body.toString(),
      inReplyTo: messageId,
      references: [?messageId],
      calendar: OutgoingCalendar(
        method: 'REPLY',
        content: CalendarReply.build(
          invite,
          attendee: attendee,
          answer: answer,
          now: now ?? DateTime.now(),
          comment: cleanNote,
        ),
      ),
    );
  }

  /// "Accepted:", "Tentatively accepted:", "Declined:", as calendar apps
  /// write them.
  static String subjectPrefix(CalendarAnswer answer) => switch (answer) {
    CalendarAnswer.accepted => 'Accepted:',
    CalendarAnswer.tentative => 'Tentatively accepted:',
    CalendarAnswer.declined => 'Declined:',
    _ => 'Answer:',
  };
}
