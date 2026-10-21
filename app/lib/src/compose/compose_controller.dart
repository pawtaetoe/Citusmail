// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import '../services/app_services.dart';

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
  const ComposeSent(this.pending);

  final PendingSend pending;
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
      showCopies = initial.cc.isNotEmpty || initial.bcc.isNotEmpty {
    for (final list in [to, cc, bcc]) {
      list.addListener(changed);
    }
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

  void setAccount(int accountId) =>
      _update(_draft.copyWith(accountId: accountId));
  void setSubject(String subject) => _update(_draft.copyWith(subject: subject));
  void setBody(String body) =>
      _update(_draft.copyWith(body: body), notify: false);

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

  /// Address suggestions for what the user is typing.
  List<MailAddress> suggest(String text) =>
      services.store.messages.suggestAddresses(text);

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

  /// Sends, after turning typed text into recipients. Returns null (and
  /// sets [problems]) if the message cannot be sent yet.
  ComposeResult? send() {
    final typedOk = [to, cc, bcc].map((l) => l.commit()).every((ok) => ok);
    _draft = _withRecipients(_draft);
    if (!typedOk) {
      problems = {ComposeProblem.invalidRecipient};
      notifyListeners();
      return null;
    }
    try {
      final pending = services.sender.send(_draft);
      _finish();
      services.worker.syncAt(pending.accountId, pending.undoUntil);
      return ComposeSent(pending);
    } on ComposeException catch (e) {
      problems = e.problems;
      notifyListeners();
      return null;
    }
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
