// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import '../../../core/state/notice.dart';
import '../../../services/app_services.dart';
import '../../accounts/state/own_addresses.dart';
import 'invitation_answers.dart';
import 'reader_state.dart';

/// Answering calendar invitations: who the user is among the guests, and
/// sending the answer to the organizer with Undo.
final class InvitationController {
  InvitationController(
    this._services, {
    required this._refresh,
    required this._notify,
  }) : answers = InvitationAnswers(_services.store);

  final AppServices _services;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;

  MailStore get _store => _services.store;

  /// The user's answers to invitations, remembered on the device.
  final InvitationAnswers answers;

  /// Changes when an answer is sent or undone, so the card updates.
  final changed = ValueNotifier<int>(0);

  /// The user among [invite]'s guests: the account it came to first,
  /// else any of their addresses. Null if they aren't on the list.
  CalendarPerson? ownAttendee(StoredMessage message, CalendarInvite invite) {
    final account = _store.accounts.byId(message.accountId);
    return (account == null ? null : invite.attendeeFor([account.email])) ??
        invite.attendeeFor(_store.ownAddresses);
  }

  /// Sends the answer to the open invitation to its organizer (and no one
  /// else), through the outbox with Undo, and remembers it. Returns null
  /// on success, or why it couldn't be sent.
  String? answer(ReaderReady r, CalendarAnswer answer, {String? note}) {
    final invite = r.view.invite;
    final account = _store.accounts.byId(r.message.accountId);
    if (invite == null || account == null || !invite.answerable) {
      return 'This invitation can\'t be answered.';
    }
    final attendee = ownAttendee(r.message, invite);
    if (attendee == null) {
      return 'You\'re not on this invitation\'s guest list, so there is '
          'nothing to answer.';
    }
    final draft = InvitationReplies.draft(
      message: r.message,
      account: account,
      invite: invite,
      attendee: attendee,
      answer: answer,
      note: note,
    );
    if (draft == null) return 'This invitation can\'t be answered.';
    final PendingSend pending;
    try {
      pending = _services.sender.send(draft);
    } on ComposeException {
      return 'The organizer\'s address isn\'t usable, so no answer was sent.';
    }
    _services.worker.syncAt(pending.accountId, pending.undoUntil);
    final previous = answers.of(invite);
    answers.remember(invite, answer);
    changed.value++;
    _refresh();
    final organizer = invite.organizer!.label;
    _notify(
      switch (answer) {
        CalendarAnswer.accepted => 'Accepted. Telling $organizer…',
        CalendarAnswer.tentative => 'Answered maybe. Telling $organizer…',
        _ => 'Declined. Telling $organizer…',
      },
      undo: () {
        if (_services.sender.cancel(pending)) {
          answers.forget(invite, previous: previous);
          changed.value++;
          _refresh();
        } else {
          _notify('Too late to undo: your answer is on its way.');
        }
      },
    );
    return null;
  }

  void dispose() => changed.dispose();
}
