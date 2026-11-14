// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_view/mail_view.dart';

import '../background/background_mail.dart';
import '../mail/send_later_times.dart';
import '../services/app_services.dart';
import '../ui/follow_up_sheet.dart' show FollowUpPick;
import 'address_book.dart';
import 'writing_help.dart';

/// Addresses in one recipient field, plus text typed but not yet turned
/// into an address.
final class RecipientList extends ChangeNotifier {
  RecipientList(List<MailAddress> initial) : _addresses = [...initial];

  final List<MailAddress> _addresses;
  String _pending = '';

  List<MailAddress> get addresses => List.unmodifiable(_addresses);
  String get pending => _pending;

  /// Text that could not be read as an address, shown as an error.
  String? invalid;

  set pending(String text) {
    _pending = text;
    invalid = null;
  }

  void add(MailAddress address) {
    if (_addresses.any(
      (a) => a.address.toLowerCase() == address.address.toLowerCase(),
    )) {
      return;
    }
    _addresses.add(address);
    notifyListeners();
  }

  void remove(MailAddress address) {
    _addresses.remove(address);
    notifyListeners();
  }

  /// Turns typed text into addresses (`Bob <bob@x.example>, carol@y`).
  /// Returns false (and keeps the text) if some of it is not an address.
  bool commit() {
    final text = _pending.trim();
    if (text.isEmpty) return true;
    final parsed = const AddressParser().parse(text);
    final found = parsed.mailboxes;
    final looksComplete = found.isNotEmpty && parsed.defects.isEmpty;
    if (!looksComplete) {
      invalid = text;
      notifyListeners();
      return false;
    }
    for (final address in found) {
      add(address);
    }
    _pending = '';
    invalid = null;
    notifyListeners();
    return true;
  }
}

/// How a compose window ended.
sealed class ComposeResult {
  const ComposeResult();
}

final class ComposeSent extends ComposeResult {
  const ComposeSent(this.pending, {this.followUp});

  final PendingSend pending;

  /// "Remind me if no reply", when it was chosen (ended by undoing the
  /// send).
  final FollowUp? followUp;
}

final class ComposeClosed extends ComposeResult {
  const ComposeClosed(this.outcome);

  final DraftOutcome outcome;
}

/// The state of one compose window: the draft being written, saved on the
/// device shortly after each change.
final class ComposeController extends ChangeNotifier {
  ComposeController(this.services, Draft initial)
    : _draft = initial,
      to = RecipientList(initial.to),
      cc = RecipientList(initial.cc),
      bcc = RecipientList(initial.bcc),
      showCopies = initial.cc.isNotEmpty || initial.bcc.isNotEmpty,
      // A draft written before (on the device, in the Drafts folder,
      // taken back from the Outbox) keeps the sign-off it has.
      signOffChosen = initial.id != null || initial.savedMessageId != null {
    for (final list in [to, cc, bcc]) {
      list.addListener(changed);
    }
    if (!signOffChosen) _draft = _withDefaultSignOff(_draft);
  }

  final AppServices services;
  final RecipientList to;
  final RecipientList cc;
  final RecipientList bcc;

  /// Whether the Cc and Bcc fields are shown.
  bool showCopies;

  Draft _draft;
  Draft get draft => _draft;

  Timer? _autosave;
  bool _finished = false;

  /// Problems found when the user tried to send.
  Set<ComposeProblem> problems = const {};

  static const autosaveDelay = Duration(seconds: 2);

  List<Account> get accounts => services.store.accounts.all();

  Account? get account => services.store.accounts.byId(_draft.accountId);

  /// Sending from another account starts with that account's sign-off,
  /// unless the user chose one for this message.
  void setAccount(int accountId) {
    final next = _draft.copyWith(accountId: accountId);
    _update(signOffChosen ? next : _withDefaultSignOff(next));
  }

  // ----------------------------------------------------------- sign-offs

  /// The user's sign-offs, in their order.
  List<SignOff> get signOffs => services.store.signOffs.all();

  /// The sign-off this message ends with, or null for none.
  SignOff? get signOff => _draft.signOff;

  /// The user picked the sign-off for this message (so it stays when the
  /// account changes).
  bool signOffChosen;

  /// A reply or forward (which may have a sign-off of its own).
  bool get answers =>
      _draft.inReplyTo != null ||
      _draft.quote.isNotEmpty ||
      _draft.attachments.any((a) => a.mimeType == 'message/rfc822');

  Draft _withDefaultSignOff(Draft d) {
    final email = services.store.accounts.byId(d.accountId)?.email;
    final signOff = email == null
        ? null
        : services.store.signOffs.defaultFor(email, reply: answers);
    return _withSignOff(d, signOff);
  }

  static Draft _withSignOff(Draft d, SignOff? signOff) => signOff == null
      ? d.copyWith(clearSignOff: true)
      : d.copyWith(signOff: signOff);

  /// Ends the message with [signOff] instead (null: none). What the user
  /// wrote stays as it is.
  void chooseSignOff(SignOff? signOff) {
    signOffChosen = true;
    _update(_withSignOff(_draft, signOff));
  }

  /// A sign-off written while writing: kept in the list when [save] (and
  /// returned), else used for this message only.
  SignOff writeSignOff({
    required String text,
    String name = '',
    bool separator = false,
    bool save = true,
  }) {
    final signOff = save
        ? services.store.signOffs.add(
            name: name.trim().isEmpty ? defaultName(text) : name,
            text: text,
            separator: separator,
          )
        : SignOff.oneOff(text: text, separator: separator);
    chooseSignOff(signOff);
    return signOff;
  }

  /// A name for a sign-off saved without one: its first line.
  static String defaultName(String text) {
    final first = text.trim().split('\n').first.trim();
    if (first.isEmpty) return 'Sign-off';
    return first.length <= 30 ? first : '${first.substring(0, 29)}…';
  }

  /// After the list was managed: the sign-off in use follows its edits;
  /// one that was removed stays in this message as it was.
  void signOffsChanged() {
    final current = _draft.signOff;
    if (current == null || !current.isSaved) {
      notifyListeners();
      return;
    }
    final stored = services.store.signOffs.byId(current.id);
    if (stored == current) {
      notifyListeners();
      return;
    }
    _update(
      _withSignOff(
        _draft,
        stored ??
            SignOff.oneOff(text: current.text, separator: current.separator),
      ),
    );
  }

  void setSubject(String subject) => _update(_draft.copyWith(subject: subject));

  /// "Remind me if no reply": when, or null for no reminder.
  FollowUpPick? get followUp => _followUp;
  FollowUpPick? _followUp;

  void setFollowUp(FollowUpPick? pick) {
    _followUp = pick?.at == null ? null : pick;
    notifyListeners();
  }

  /// Ask the recipients' mail apps for a read receipt (their choice).
  void setRequestReceipt(bool on) =>
      _update(_draft.copyWith(requestReceipt: on));

  /// What the user typed. Typing ends the offer to undo the AI's text.
  void setBody(String body) {
    final hadUndo = _beforeWriting != null;
    _beforeWriting = null;
    _update(_draft.copyWith(body: body), notify: hadUndo);
  }

  // ------------------------------------------------- writing help (AI)

  /// "Write with AI" in this window (it keeps its answers).
  final writing = WritingAssistant();

  /// The user's name, as their account has it.
  String? get userName => account?.displayName;

  /// Whether this forwards an email (with its text quoted below).
  bool get forwards =>
      _draft.quote.trimLeft().startsWith(WritingHelp.forwardMark);

  /// The email this answers or forwards, as "Draft a reply" sends it, or
  /// null for a new message: the quote as the user left it (or the
  /// stored email's text if they removed it), with the stored email's
  /// sender, recipients, date and subject. Nothing else from the mailbox.
  PromptMail? replySource() {
    if (forwards) {
      return WritingHelp.forwarded(
        _draft.quote.trimLeft(),
        files: [
          for (final a in _draft.attachments)
            if (a.mimeType != 'message/rfc822') a.fileName,
        ],
      );
    }
    final id = _draft.answeredMessageId;
    final original = id == null ? null : services.store.messages.byId(id);
    if (original == null && _draft.inReplyTo == null) return null;
    var text = WritingHelp.unquote(_draft.quote);
    if (text.isEmpty && original != null) {
      final raw = services.store.messages.body(original.id);
      if (raw != null) {
        try {
          text = MessageView.parse(raw).body.plainText.trim();
        } on Object {
          text = '';
        }
      }
    }
    if (text.isEmpty) return null;
    return PromptMail(
      from: switch (original?.from) {
        final a? => _display(a),
        null => 'The sender',
      },
      to: [
        if (original != null)
          for (final a in services.store.messages.addresses(original.id, 'to'))
            _display(a),
      ],
      date: original?.sentAt ?? original?.receivedAt,
      subject: original?.subject ?? _draft.subject,
      body: text,
    );
  }

  static String _display(MailAddress a) {
    final name = a.displayName?.trim();
    return name == null || name.isEmpty ? a.address : '$name <${a.address}>';
  }

  /// The body before the AI's text went in, while Undo is offered.
  String? _beforeWriting;

  /// Whether the AI's text went in and can be taken back.
  bool get canUndoWriting => _beforeWriting != null;

  /// Puts the AI's [text] into the body: instead of what is there
  /// ([replace]) or below it. Only the body changes: never the
  /// recipients, subject, attachments, sign-off or quote, and nothing is
  /// sent. Returns the new body.
  String useWriting(String text, {required bool replace}) {
    final before = _draft.body;
    final next = replace || before.trim().isEmpty
        ? text
        : '${before.trimRight()}\n\n$text';
    _update(_draft.copyWith(body: next));
    _beforeWriting = before;
    notifyListeners();
    return next;
  }

  /// Puts back the body from before the AI's text; returns it, or null
  /// if there is nothing to undo.
  String? undoWriting() {
    final before = _beforeWriting;
    if (before == null) return null;
    _beforeWriting = null;
    _update(_draft.copyWith(body: before));
    return before;
  }

  /// No more Undo for the AI's text (the note was closed).
  void keepWriting() {
    if (_beforeWriting == null) return;
    _beforeWriting = null;
    notifyListeners();
  }

  /// The quoted or forwarded text below the sign-off (it can be trimmed).
  void setQuote(String quote) =>
      _update(_draft.copyWith(quote: quote), notify: false);

  void addAttachments(List<DraftAttachment> files) =>
      _update(_draft.copyWith(attachments: [..._draft.attachments, ...files]));

  void removeAttachment(DraftAttachment file) => _update(
    _draft.copyWith(attachments: [..._draft.attachments]..remove(file)),
  );

  void toggleCopies() {
    showCopies = !showCopies;
    notifyListeners();
  }

  /// A recipient list changed.
  void changed() => _update(_withRecipients(_draft));

  /// Address suggestions for what the user is typing (read from the
  /// store once, then matched in memory).
  List<MailAddress> suggest(String text) => _addressBook.suggest(text);

  late final _addressBook = AddressBook(
    services.store.messages.suggestionCandidates,
  );

  Draft _withRecipients(Draft d) =>
      d.copyWith(to: to.addresses, cc: cc.addresses, bcc: bcc.addresses);

  void _update(Draft next, {bool notify = true}) {
    if (_finished) return;
    _draft = next;
    problems = const {};
    _autosave?.cancel();
    _autosave = Timer(autosaveDelay, _saveNow);
    if (notify) notifyListeners();
  }

  void _saveNow() {
    if (_finished || _draft.isEmpty) return;
    _draft = services.drafts.save(_draft);
  }

  /// Sends, after turning typed text into recipients; with [at], at that
  /// time ("Send later"; it waits in the Outbox until then). Returns null
  /// (and sets [problems]) if the message cannot be sent yet.
  ComposeResult? send({DateTime? at}) {
    final typedOk = [to, cc, bcc].map((l) => l.commit()).every((ok) => ok);
    _draft = _withRecipients(_draft);
    if (!typedOk) {
      problems = {ComposeProblem.invalidRecipient};
      notifyListeners();
      return null;
    }
    try {
      final pending = _sendOrSchedule(at);
      _finish();
      services.worker.syncAt(pending.accountId, pending.undoUntil);
      if (pending.scheduledFor case final due?) {
        services.worker.syncAt(pending.accountId, due);
        unawaited(BackgroundMail.checkWhenDue(services.store));
      }
      final followUp = _remind(pending);
      if (followUp != null) {
        // Android: a background check when it is due.
        unawaited(BackgroundMail.checkWhenDue(services.store));
      }
      return ComposeSent(pending, followUp: followUp);
    } on ComposeException catch (e) {
      problems = e.problems;
      notifyListeners();
      return null;
    }
  }

  /// Sets the follow-up chosen for [pending]: relative times count from
  /// when it goes out.
  FollowUp? _remind(PendingSend pending) {
    final pick = _followUp;
    if (pick == null) return null;
    final sentAt = pending.scheduledFor ?? DateTime.now();
    final due = pick.dueFor(sentAt);
    if (due == null) return null;
    try {
      return FollowUpReminders(services.store).remind(
        FollowUp(
          messageId: pending.messageId,
          accountId: pending.accountId,
          due: due.toUtc(),
          sentAt: sentAt.toUtc(),
          subject: _draft.subject.trim(),
          recipients: [..._draft.to, ..._draft.cc],
          inReplyTo: _draft.inReplyTo,
          references: _draft.references,
        ),
      );
    } on Object catch (e) {
      debugPrint('follow-up: ${e.runtimeType}');
      return null;
    }
  }

  /// Whether the message could be sent as it is (asked before choosing a
  /// time for it); if not, sets [problems] to say why.
  bool readyToSend() {
    final typedOk = [to, cc, bcc].map((l) => l.commit()).every((ok) => ok);
    _draft = _withRecipients(_draft);
    problems = typedOk
        ? services.sender.messages.problems(_draft, account)
        : {ComposeProblem.invalidRecipient};
    notifyListeners();
    return problems.isEmpty;
  }

  /// A time only seconds away (picked for the current minute) is just a
  /// send.
  PendingSend _sendOrSchedule(DateTime? at) {
    if (at != null) {
      try {
        return services.sender.schedule(
          _draft,
          at,
          now: SendLaterTimes.clock(),
        );
      } on ArgumentError {
        // Too soon to schedule: send it now.
      }
    }
    return services.sender.send(_draft);
  }

  /// The window closes without sending: the draft goes to the server's
  /// Drafts folder (or is dropped if empty).
  ComposeResult close() {
    for (final list in [to, cc, bcc]) {
      list.commit();
    }
    _draft = _withRecipients(_draft);
    final outcome = services.drafts.close(_draft);
    _finish();
    services.worker.requestSync(_draft.accountId);
    return ComposeClosed(outcome);
  }

  /// Throws the draft away.
  ComposeResult discard() {
    services.drafts.discard(_draft);
    _finish();
    services.worker.requestSync(_draft.accountId);
    return const ComposeClosed(DraftOutcome.discarded);
  }

  void _finish() {
    _finished = true;
    _autosave?.cancel();
  }

  @override
  void dispose() {
    _autosave?.cancel();
    for (final list in [to, cc, bcc]) {
      list.dispose();
    }
    super.dispose();
  }
}
