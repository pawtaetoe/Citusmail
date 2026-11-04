// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_view/mail_view.dart';

import '../background/background_mail.dart';
import '../services/app_services.dart';
import 'invitation_answers.dart';
import 'mail_location.dart';
import 'message_list_model.dart';
import 'send_later_times.dart';

/// How a sender can be blocked.
final class BlockChoice {
  const BlockChoice({
    required this.address,
    required this.domain,
    required this.fromAddress,
    required this.fromDomain,
  });

  final String address;

  /// The sender's domain, or null when blocking it would make no sense (a
  /// free mail service, or the user's own domain).
  final String? domain;

  /// Messages in the inboxes from the address, and from the domain.
  final int fromAddress;
  final int fromDomain;
}

/// What the reading pane shows.
sealed class ReaderState {
  const ReaderState();

  StoredMessage? get message => null;
}

final class ReaderEmpty extends ReaderState {
  const ReaderEmpty();
}

final class ReaderLoading extends ReaderState {
  const ReaderLoading(this.message);

  @override
  final StoredMessage message;
}

final class ReaderReady extends ReaderState {
  const ReaderReady(
    this.message,
    this.view, {
    required this.to,
    required this.cc,
    required this.trust,
    required this.unsubscribe,
    this.unsubscribed,
    this.imagesShown = false,
  });

  @override
  final StoredMessage message;
  final MessageView view;

  /// What the message checks found (phishing signs, risky files).
  final TrustReport trust;

  /// How to unsubscribe from the message's list, if it has one.
  final UnsubscribePlan unsubscribe;

  /// When the user unsubscribed from this list, if they did.
  final Unsubscription? unsubscribed;

  /// Whether the message's remote images may load (the user asked, for
  /// this message or for this verified sender).
  final bool imagesShown;

  /// Whether images may be loaded at all: never for mail that looks like
  /// a scam.
  bool get imagesAllowed => trust.level != TrustLevel.danger;

  ReaderReady copyWith({
    StoredMessage? message,
    Unsubscription? unsubscribed,
    bool? imagesShown,
  }) => ReaderReady(
    message ?? this.message,
    view,
    to: to,
    cc: cc,
    trust: trust,
    unsubscribe: unsubscribe,
    unsubscribed: unsubscribed ?? this.unsubscribed,
    imagesShown: imagesShown ?? this.imagesShown,
  );
  final List<MailAddress> to;
  final List<MailAddress> cc;
}

final class ReaderFailed extends ReaderState {
  const ReaderFailed(this.message, this.reason);

  @override
  final StoredMessage message;
  final String reason;
}

/// Counts for the sidebar and section headers, read together.
final class MailCounts {
  const MailCounts({
    required this.sections,
    required this.perAccountUnread,
    required this.folderUnread,
    required this.outbox,
    this.snoozed = 0,
    this.followUps = 0,
  });

  static const empty = MailCounts(
    sections: {},
    perAccountUnread: {},
    folderUnread: {},
    outbox: 0,
  );

  /// Messages snoozed in the inboxes.
  final int snoozed;

  /// Sent messages waiting for a reply ("Remind me if no reply"),
  /// including those back with "No reply yet".
  final int followUps;

  final Map<SmartSection, SectionCount> sections;
  final Map<int, int> perAccountUnread;
  final Map<int, int> folderUnread;
  final int outbox;

  /// Unread mail in the Smart Inbox (mail waiting in the Screener isn't
  /// counted until its sender is let in, nor snoozed mail until it comes
  /// back).
  int get inboxUnread => unreadIn(sections);

  static int unreadIn(Map<SmartSection, SectionCount> sections) => [
    for (final MapEntry(:key, :value) in sections.entries)
      if (key != SmartSection.screener && key != SmartSection.snoozed)
        value.unread,
  ].fold(0, (sum, n) => sum + n);
}

/// How the accounts' sync is going, in one line for the list header.
sealed class SyncStatus {
  const SyncStatus();
}

final class SyncIdle extends SyncStatus {
  const SyncIdle(this.lastSynced);

  final DateTime? lastSynced;
}

final class SyncRunning extends SyncStatus {
  const SyncRunning();
}

final class SyncProblem extends SyncStatus {
  const SyncProblem(
    this.kind,
    this.account, {
    this.accountId,
    this.oauth = false,
  });

  final SyncFailureKind kind;
  final String account;
  final int? accountId;

  /// The account signs in with OAuth: a refused login means its sign-in
  /// ended, not a wrong password.
  final bool oauth;
}

/// The mail screen's state, in separate pieces so each part of the screen
/// rebuilds only when its own data changes:
///
/// - [location]: where the user is;
/// - [list]: what the list shows (paged; index reads only);
/// - [counts]: sidebar and section counts;
/// - [reader]: the open message;
/// - [selection]: messages picked for a bulk action;
/// - [status]: sync status.
final class MailController {
  MailController(this.services)
    : list = MessageListModel(services.store),
      codeCleaner = CodeCleaner(services.store, services.actions) {
    _events = services.worker.events.listen(_onSyncEvent);
    list.show(location.value);
    _refreshCounts();
    _refreshCodesOffer();
    wakeSnoozes();
    checkFollowUps();
    // Android: a background check when the next scheduled message (or
    // follow-up) is due.
    unawaited(BackgroundMail.checkWhenDue(_store));
  }

  final AppServices services;
  final MessageListModel list;
  final location = ValueNotifier<MailLocation>(const InboxLocation());
  final counts = ValueNotifier<MailCounts>(MailCounts.empty);
  final reader = ValueNotifier<ReaderState>(const ReaderEmpty());
  final selection = ValueNotifier<Set<int>>(const {});
  final status = ValueNotifier<SyncStatus>(const SyncIdle(null));

  /// Moves old verification codes out of the inbox, once agreed.
  final CodeCleaner codeCleaner;

  /// Whether the Verification section asks to tidy up old codes.
  final codesOffer = ValueNotifier<bool>(false);

  late final StreamSubscription<SyncEvent> _events;
  final Map<int, SyncEvent> _lastEvent = {};
  Timer? _refreshSoon;
  bool _disposed = false;

  MailStore get _store => services.store;

  StoredMessage? get selected => reader.value.message;

  /// Opens the compose window (set by the screen that can show it).
  void Function(Draft draft)? onCompose;

  /// Tells the user something; with [undo], offers to take it back.
  void Function(String message, {VoidCallback? undo})? onNotice;

  /// Asks for an account's new password or sign-in (set by the screen
  /// that can show it).
  void Function(Account account)? onReconnect;

  /// Announces snoozed mail that came back (set by the screen that can
  /// post notifications).
  void Function(BackFromSnooze back)? onBackFromSnooze;

  /// Announces sent mail back with "No reply yet" (set by the screen that
  /// can post notifications).
  void Function()? onFollowUpsBack;

  /// Fixes the login of the account in [status], if that is the problem.
  void reconnect(SyncProblem problem) {
    final account = problem.accountId == null
        ? null
        : _store.accounts.byId(problem.accountId!);
    if (account != null) onReconnect?.call(account);
  }

  // ------------------------------------------------------------ location

  void goTo(MailLocation target) {
    clearSelection();
    location.value = target;
    list.show(target);
    // Views like Gmail's Starred are not synced in the background.
    if (target case FolderLocation(:final mailboxId)
        when _store.mailboxes.byId(mailboxId)?.isView ?? false) {
      unawaited(
        services.worker
            .syncFolder(mailboxId)
            .then((_) => refresh())
            .catchError((Object _) {}),
      );
    }
  }

  void search(String text) {
    final trimmed = text.trim();
    goTo(trimmed.isEmpty ? const InboxLocation() : SearchLocation(trimmed));
  }

  // --------------------------------------------------------------- lists

  /// Shows more of a flat list: stored messages first, then older mail
  /// from the server.
  Future<void> loadMore() async {
    if (list.loadMoreStored() || list.loadingOlder || list.reachedEnd) return;
    final folders = _foldersToExtend(location.value);
    if (folders.isEmpty) {
      list.setLoadingOlder(false, reachedEnd: true);
      return;
    }
    list.setLoadingOlder(true);
    var added = 0;
    try {
      for (final mailboxId in folders) {
        added += await services.worker.fetchOlder(mailboxId);
      }
    } on SyncWorkerException {
      // Offline: try again on the next scroll.
    }
    if (_disposed) return;
    list.setLoadingOlder(false, reachedEnd: added == 0);
    list.loadMoreStored();
  }

  List<int> _foldersToExtend(MailLocation at) => switch (at) {
    FolderLocation(:final mailboxId) => [mailboxId],
    InboxLocation(:final accountId) ||
    SectionLocation(:final accountId) => _store.messages.inboxIds(
      accountIds: accountId == null ? null : [accountId],
    ),
    _ => const [],
  };

  /// Re-reads the list, the counts and the open message.
  void refresh() {
    if (_disposed) return;
    list.refresh();
    _refreshCounts();
    _refreshSelected();
    _refreshCodesOffer();
    _scheduleWake();
  }

  void _refreshCounts() {
    final accounts = _store.accounts.all();
    counts.value = MailCounts(
      sections: _store.messages.sectionCounts(),
      perAccountUnread: {
        for (final a in accounts)
          a.id: MailCounts.unreadIn(
            _store.messages.sectionCounts(accountIds: [a.id]),
          ),
      },
      folderUnread: _store.messages.unreadCounts(),
      outbox: _store.outbox.sends().length,
      snoozed: _store.snoozes.count(),
      followUps: followUps.all().length,
    );
  }

  // ---------------------------------------------------------- old codes

  void _refreshCodesOffer() =>
      codesOffer.value = codeCleaner.shouldAsk(DateTime.now().toUtc());

  /// After a sync: moves old codes out of the inbox (at most once an hour,
  /// once the user agreed), and says so with Undo. The open message and
  /// selected ones stay.
  void tidyCodes([DateTime? now]) {
    if (_disposed) return;
    final done = codeCleaner.run(
      now ?? DateTime.now().toUtc(),
      except: {?selected?.id, ...selection.value},
    );
    if (done == null) {
      _refreshCodesOffer();
      return;
    }
    for (final receipt in done.receipts) {
      for (final id in receipt.accountIds) {
        services.worker.syncAt(id, receipt.undoUntil);
      }
    }
    refresh();
    onNotice?.call(
      done.count == 1
          ? 'Tidied up 1 old code'
          : 'Tidied up ${done.count} old codes',
      undo: () {
        final undone = codeCleaner.undo(done);
        refresh();
        if (!undone) {
          onNotice?.call('Too late to undo: the change reached the server.');
        }
      },
    );
  }

  /// "Turn on" in the Verification section: agrees, and tidies up now.
  void agreeToTidyCodes() {
    codeCleaner.settings.agree();
    codesOffer.value = false;
    tidyCodes();
  }

  /// "Not now": asked again in a month.
  void declineTidyCodes() {
    codeCleaner.settings.decline(DateTime.now().toUtc());
    codesOffer.value = false;
  }

  // -------------------------------------------------------------- reader

  /// Opens [message]: marks it read and shows it, downloading it first if
  /// needed. Drafts open in the compose window instead.
  Future<void> open(StoredMessage message) async {
    if (_isDraft(message)) return _editDraft(message);
    if (!message.flags.seen) {
      services.actions.markRead([message]);
      services.worker.requestSync(message.accountId);
      message = _store.messages.byId(message.id) ?? message;
      list.refresh();
      _refreshCounts();
    }
    reader.value = ReaderLoading(message);
    try {
      final ready = await readerFor(message);
      if (_disposed || selected?.id != message.id) return;
      reader.value = ready;
    } on BodyUnavailableException catch (e) {
      if (_disposed || selected?.id != message.id) return;
      reader.value = ReaderFailed(message, switch (e.problem) {
        BodyProblem.tooLarge => 'This message is too large to show.',
        BodyProblem.gone => 'This message is no longer on the server.',
        BodyProblem.folderChanged =>
          'The folder changed on the server. Try again after the next sync.',
      });
    } on SyncWorkerException catch (e) {
      if (_disposed || selected?.id != message.id) return;
      reader.value = ReaderFailed(message, switch (e.failure.kind) {
        SyncFailureKind.network =>
          'Can\'t reach the server. The message opens once you\'re online.',
        SyncFailureKind.authentication =>
          _store.accounts.byId(message.accountId)?.usesOAuth ?? false
              ? 'The sign-in has ended. Sign in again from the account menu.'
              : 'The server didn\'t accept your password.',
        SyncFailureKind.security =>
          'The connection was refused for security reasons.',
        SyncFailureKind.server =>
          'The server had a problem: ${e.failure.message}',
      });
    }
  }

  /// [message] read and checked, as the reading pane shows it, without
  /// opening it (it stays unread): downloads it first if needed. Throws
  /// [BodyUnavailableException] or [SyncWorkerException].
  Future<ReaderReady> readerFor(StoredMessage message) async {
    if (_store.messages.body(message.id) == null) {
      await services.worker.loadBody(message.id);
    }
    final raw = _store.messages.body(message.id);
    if (raw == null) throw const BodyUnavailableException(BodyProblem.gone);
    // Parsing and checking a large message must not block the UI.
    final (view, trust, plan) = await compute(_parseAndCheck, (
      raw,
      _trustContext(message),
    ));
    return ReaderReady(
      _store.messages.byId(message.id) ?? message,
      view,
      to: _store.messages.addresses(message.id, 'to'),
      cc: _store.messages.addresses(message.id, 'cc'),
      trust: trust,
      unsubscribe: plan,
      unsubscribed: _unsubscription(message),
      imagesShown:
          trust.level != TrustLevel.danger &&
          trust.verified &&
          _store.imageSenders.isAllowed(message.from?.address),
    );
  }

  /// When the user unsubscribed from [message]'s list, if they did.
  Unsubscription? unsubscriptionFor(StoredMessage message) =>
      _unsubscription(message);

  /// What the message checks need besides the message: which server's
  /// verification results to believe, learned from the account's recent
  /// inbox mail, and the user's own domains. Null for the user's own
  /// mail (Sent, Drafts), which needs no checking.
  TrustContext? _trustContext(StoredMessage message) {
    final use = _store.mailboxes.byId(message.mailboxId)?.specialUse;
    if (use == SpecialUse.sent || use == SpecialUse.drafts) return null;
    final inbox = _store.mailboxes.inbox(message.accountId);
    return TrustContext(
      trustedAuthServId: inbox == null
          ? null
          : AuthServIds.learn(
              _store.messages.firstHeaderValues(
                inbox.id,
                'authentication-results',
              ),
            ),
      ownDomains: {
        for (final account in _store.accounts.all())
          ?Domains.registrable(
            account.email.substring(account.email.lastIndexOf('@') + 1),
          ),
      },
    );
  }

  void closeMessage() => reader.value = const ReaderEmpty();

  // -------------------------------------------------------------- images

  /// Loads the open message's images; with [always], also for later mail
  /// from this sender (only offered when the server verified the sender).
  void showImages(ReaderReady r, {bool always = false}) {
    if (!r.imagesAllowed) return;
    final from = r.message.from?.address;
    if (always && r.trust.verified && from != null) {
      try {
        _store.imageSenders.allow(from);
      } on ArgumentError {
        // An address that can't be stored: load this time only.
      }
    }
    if (reader.value case final ReaderReady open
        when open.message.id == r.message.id) {
      reader.value = open.copyWith(imagesShown: true);
    }
  }

  // --------------------------------------------------------- unsubscribe

  /// What identifies [message]'s list (List-Id, else the sender).
  static String? _listKey(StoredMessage message) => Unsubscription.listKeyOf(
    listId: message.listId,
    fromAddress: message.from?.address,
  );

  Unsubscription? _unsubscription(StoredMessage message) {
    final key = _listKey(message);
    return key == null
        ? null
        : _store.unsubscriptions.find(message.accountId, key);
  }

  /// Inbox mail from the same list as [r] (to offer archiving it).
  List<StoredMessage> sameList(ReaderReady r) => _store.messages.inboxFromList(
    r.message.accountId,
    listId: r.message.listId,
    fromAddress: r.message.listId == null ? r.message.from?.address : null,
  );

  /// Unsubscribes with [method]. One-click requests go out now; an email
  /// goes through the outbox (so it also works offline). For a web page
  /// the caller opens it and then calls this to remember it. Returns null
  /// on success, or why it failed.
  Future<String?> unsubscribe(
    ReaderReady r,
    UnsubscribeMethod method, {
    bool archiveList = false,
  }) async {
    final problem = switch (method) {
      OneClickMethod(:final url) => await _oneClick(url),
      EmailMethod(:final request) => _unsubscribeEmail(r, request),
      WebPageMethod() => null,
    };
    if (problem != null) return problem;
    final kind = switch (method) {
      OneClickMethod() => UnsubscribeKind.oneClick,
      EmailMethod() => UnsubscribeKind.email,
      WebPageMethod() => UnsubscribeKind.webPage,
    };
    final key = _listKey(r.message);
    if (key != null) {
      final record = _store.unsubscriptions.record(
        accountId: r.message.accountId,
        listKey: key,
        listName: r.unsubscribe.listName,
        kind: kind,
      );
      if (reader.value case final ReaderReady open
          when open.message.id == r.message.id) {
        reader.value = open.copyWith(unsubscribed: record);
      }
    }
    final name = r.unsubscribe.listName;
    final done = switch (kind) {
      UnsubscribeKind.webPage => 'Opened the unsubscribe page for $name',
      UnsubscribeKind.email => 'Unsubscribe email to $name is on its way',
      UnsubscribeKind.oneClick => 'Unsubscribed from $name',
    };
    final earlier = archiveList ? sameList(r) : const <StoredMessage>[];
    if (earlier.isNotEmpty) {
      archive(earlier, done: '$done. Archived ${earlier.length}.');
    } else {
      onNotice?.call(done);
    }
    return null;
  }

  /// Null on success, or why it failed.
  Future<String?> _oneClick(Uri url) async =>
      switch (await services.oneClick.unsubscribe(url)) {
        OneClickDone() => null,
        OneClickFailed(:final reason) => reason,
      };

  /// Queues the email; null on success, or why it can't be sent.
  String? _unsubscribeEmail(ReaderReady r, MailtoRequest request) {
    final at = request.address.lastIndexOf('@');
    try {
      final pending = services.sender.send(
        Draft(
          accountId: r.message.accountId,
          to: [
            MailAddress(
              localPart: request.address.substring(0, at),
              domain: request.address.substring(at + 1),
            ),
          ],
          subject: request.subject ?? 'unsubscribe',
          body: request.body ?? 'unsubscribe',
        ),
      );
      services.worker.syncAt(pending.accountId, pending.undoUntil);
      return null;
    } on ComposeException {
      return 'Couldn\'t write the unsubscribe email: its address isn\'t usable.';
    }
  }

  /// Opens the message after (or before) the open one in the list.
  void openNext({bool previous = false}) {
    final visible = list.visible;
    if (visible.isEmpty) return;
    final index = visible.indexWhere((m) => m.id == selected?.id);
    final next = index < 0
        ? 0
        : (previous ? index - 1 : index + 1).clamp(0, visible.length - 1);
    if (next != index) unawaited(open(visible[next]));
  }

  void _refreshSelected() {
    final current = selected;
    if (current == null) return;
    final fresh = _store.messages.byId(current.id);
    if (fresh == null) {
      reader.value = const ReaderEmpty();
      return;
    }
    reader.value = switch (reader.value) {
      ReaderLoading() => ReaderLoading(fresh),
      final ReaderReady ready => ready.copyWith(message: fresh),
      ReaderFailed(:final reason) => ReaderFailed(fresh, reason),
      ReaderEmpty() => const ReaderEmpty(),
    };
  }

  // ----------------------------------------------------------- selection

  bool get selecting => selection.value.isNotEmpty;

  void toggleSelected(StoredMessage m) {
    final next = {...selection.value};
    if (!next.remove(m.id)) next.add(m.id);
    selection.value = next;
  }

  /// Selects from the last selected message to [m] (Shift-click).
  void selectRange(StoredMessage m) {
    final visible = list.visible;
    final anchor = visible.lastIndexWhere(
      (x) => selection.value.contains(x.id),
    );
    final end = visible.indexWhere((x) => x.id == m.id);
    if (anchor < 0 || end < 0) return toggleSelected(m);
    final (from, to) = anchor < end ? (anchor, end) : (end, anchor);
    selection.value = {
      ...selection.value,
      for (var i = from; i <= to; i++) visible[i].id,
    };
  }

  void selectAllVisible() =>
      selection.value = {for (final m in list.visible) m.id};

  void clearSelection() {
    if (selection.value.isNotEmpty) selection.value = const {};
  }

  /// The selected messages, or else the open one.
  List<StoredMessage> get targets {
    if (selection.value.isNotEmpty) {
      return [for (final id in selection.value) ?_store.messages.byId(id)];
    }
    return [?selected];
  }

  // ------------------------------------------------------------- actions

  void togglePin(List<StoredMessage> messages) {
    if (messages.isEmpty) return;
    final on = !messages.every((m) => m.flags.flagged);
    final receipt = services.actions.markFlagged(messages, flagged: on);
    _afterFlags(receipt, on ? 'Pinned' : 'Unpinned', messages.length);
  }

  void toggleRead(List<StoredMessage> messages) {
    if (messages.isEmpty) return;
    final read = !messages.every((m) => m.flags.seen);
    final receipt = services.actions.markRead(messages, read: read);
    _afterFlags(
      receipt,
      read ? 'Marked as read' : 'Marked as unread',
      messages.length,
    );
  }

  void markSectionRead(SmartSection section) {
    final accountId = location.value.accountId;
    final unread = _store.messages.list(
      MessageQuery(
        inboxesOnly: true,
        accountIds: accountId == null ? null : [accountId],
        section: section,
        unreadOnly: true,
        limit: 500,
      ),
    );
    if (unread.isEmpty) return;
    final receipt = services.actions.markRead(unread);
    _afterFlags(receipt, 'Marked as read', unread.length, alwaysUndo: true);
  }

  void _afterFlags(
    FlagReceipt receipt,
    String done,
    int count, {
    bool alwaysUndo = false,
  }) {
    for (final id in receipt.accountIds) {
      services.worker.requestSync(id);
    }
    clearSelection();
    refresh();
    if (count > 1 || alwaysUndo) {
      onNotice?.call(
        '$done ($count)',
        undo: () {
          services.actions.undo(receipt);
          refresh();
        },
      );
    }
  }

  /// The account's Archive folder, if it has one. On Gmail, archiving
  /// means moving to All Mail (the message leaves the inbox, nothing else).
  StoredMailbox? archiveFor(StoredMessage m) => _archiveFolder(m.accountId);

  StoredMailbox? _archiveFolder(int accountId) =>
      MailActions.archiveFolder(_store, accountId);

  bool isInTrash(StoredMessage m) =>
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.trash;

  /// Archives into each account's Archive folder (skipping messages already
  /// there or in accounts without one).
  void archive(List<StoredMessage> messages, {String? done}) {
    final byAccount = <int, List<StoredMessage>>{};
    for (final m in messages) {
      final archive = archiveFor(m);
      if (archive != null && archive.id != m.mailboxId) {
        byAccount.putIfAbsent(m.accountId, () => []).add(m);
      }
    }
    if (byAccount.isEmpty) {
      onNotice?.call('There is no Archive folder for this account.');
      return;
    }
    final count = byAccount.values.fold(0, (sum, g) => sum + g.length);
    _remove([
      for (final MapEntry(key: accountId, value: group) in byAccount.entries)
        () => services.actions.move(group, _archiveFolder(accountId)!),
    ], done ?? (count == 1 ? 'Archived' : 'Archived $count'));
  }

  void moveTo(List<StoredMessage> messages, StoredMailbox target) => _remove([
    () => services.actions.move(messages, target),
  ], 'Moved to ${_folderName(target)}');

  /// Moves to Trash (or deletes for good when already in Trash; the caller
  /// confirms that).
  void delete(List<StoredMessage> messages) => _remove(
    [() => services.actions.delete(messages)],
    messages.every(isInTrash)
        ? 'Deleted'
        : (messages.length == 1
              ? 'Moved to Trash'
              : 'Moved ${messages.length} to Trash'),
  );

  /// "Always move mail from this sender here", then moves this message.
  void moveAlways(StoredMessage message, StoredMailbox target) {
    final from = message.from?.address;
    if (from != null && canHaveRules(target)) {
      try {
        _store.folderRules.add(
          accountId: target.accountId,
          mailboxId: target.id,
          field: RuleField.fromAddress,
          value: from,
        );
      } on ArgumentError {
        // An address a rule can't hold: just move this one.
      }
    }
    moveTo([message], target);
  }

  /// Removes messages from the list with [changes], opens the next message
  /// if the open one left, and offers Undo for a few seconds ([alsoUndo]
  /// reverses anything else the action did).
  void _remove(
    List<RemovalReceipt Function()> changes,
    String done, {
    VoidCallback? alsoUndo,
  }) {
    final open = selected;
    final visible = list.visible;
    final receipts = [for (final change in changes) change()];
    final removedIds = {
      for (final r in receipts)
        for (final row in r.snapshot.messages) row['id']! as int,
    };
    for (final receipt in receipts) {
      for (final id in receipt.accountIds) {
        services.worker.syncAt(id, receipt.undoUntil);
      }
    }
    clearSelection();
    _leaveList(open, visible, removedIds);
    onNotice?.call(
      done,
      undo: () {
        alsoUndo?.call();
        final undone = receipts.every(services.actions.undo);
        refresh();
        if (!undone) {
          onNotice?.call('Too late to undo: the change reached the server.');
        }
      },
    );
  }

  /// After [removedIds] left the list: refreshes, and if [open] was one
  /// of them, opens the next message (or the one before).
  void _leaveList(
    StoredMessage? open,
    List<StoredMessage> visible,
    Set<int> removedIds,
  ) {
    StoredMessage? next;
    if (open != null && removedIds.contains(open.id)) {
      final index = visible.indexWhere((m) => m.id == open.id);
      next = [
        ...visible.skip(index + 1),
        ...visible.take(index < 0 ? 0 : index).toList().reversed,
      ].where((m) => !removedIds.contains(m.id)).firstOrNull;
      reader.value = const ReaderEmpty();
    }
    refresh();
    if (next != null) unawaited(this.open(next));
  }

  // -------------------------------------------------------------- snooze

  Timer? _wakeTimer;

  /// Whether [m] can be snoozed: inbox mail with a Message-ID (what keeps
  /// it the same message on every device).
  bool canSnooze(StoredMessage m) =>
      m.messageId != null &&
      (_store.mailboxes.byId(m.mailboxId)?.isInbox ?? false);

  /// When [m] comes back, while it is snoozed.
  DateTime? snoozedUntil(StoredMessage m) {
    final id = m.messageId;
    if (id == null || m.section != SmartSection.snoozed) return null;
    return list.snoozedUntil[id] ?? _store.snoozes.find(id)?.until;
  }

  /// Snoozes [messages] until [until] (or changes when they come back),
  /// says [done], and offers Undo. They leave the inbox now; nothing
  /// changes on the mail server.
  void snooze(List<StoredMessage> messages, DateTime until, String done) {
    final targets = [
      for (final m in messages)
        if (canSnooze(m)) m,
    ];
    if (targets.isEmpty) {
      onNotice?.call('This email can\'t be snoozed.');
      return;
    }
    final ids = {for (final m in targets) m.messageId!};
    final previous = {for (final id in ids) id: _store.snoozes.find(id)};
    _store.transaction(() {
      for (final id in ids) {
        _store.snoozes.snooze(id, until);
      }
    });
    final open = selected;
    final visible = list.visible;
    clearSelection();
    if (location.value is SnoozedLocation) {
      refresh();
    } else {
      _leaveList(open, visible, {for (final m in targets) m.id});
    }
    onNotice?.call(
      done,
      undo: () {
        _store.transaction(() {
          for (final MapEntry(key: id, value: before) in previous.entries) {
            if (before == null) {
              _store.snoozes.cancel(id);
            } else {
              _store.snoozes.snooze(id, before.until);
            }
          }
        });
        refresh();
      },
    );
  }

  /// Brings [messages] back now, where they were in the inbox (not as
  /// new), with Undo.
  void unsnooze(List<StoredMessage> messages) {
    final ended = <Snooze>[];
    _store.transaction(() {
      for (final m in messages) {
        final id = m.messageId;
        if (id == null) continue;
        if (_store.snoozes.cancel(id) case final s?) ended.add(s);
      }
    });
    if (ended.isEmpty) return;
    final open = selected;
    final visible = list.visible;
    clearSelection();
    if (location.value is SnoozedLocation) {
      _leaveList(open, visible, {for (final m in messages) m.id});
    } else {
      refresh();
    }
    onNotice?.call(
      ended.length == 1 ? 'Unsnoozed' : 'Unsnoozed ${ended.length}',
      undo: () {
        _store.transaction(() {
          for (final s in ended) {
            _store.snoozes.snooze(s.messageId, s.until);
          }
        });
        refresh();
      },
    );
  }

  /// Brings back snoozed mail whose time came (or that got a reply),
  /// marked unread, and announces it ([onBackFromSnooze]). Run after each
  /// sync, when the app comes to the foreground, and at the next due time.
  void wakeSnoozes([DateTime? now]) {
    if (_disposed) return;
    try {
      final back = SnoozeWaker(_store, services.actions).wake(now: now);
      if (!back.isEmpty) {
        for (final id in back.accountIds) {
          services.worker.requestSync(id);
        }
        refresh();
        onBackFromSnooze?.call(back);
      }
    } on Object catch (e) {
      debugPrint('snooze: ${e.runtimeType}');
    }
    _scheduleWake();
  }

  /// Coming back to the app: snoozed mail and follow-ups that are due.
  void onResume() {
    wakeSnoozes();
    checkFollowUps();
  }

  /// A timer for the next snooze or follow-up due. Checked at least
  /// hourly: timers may stop while the device sleeps (coming back to the
  /// app checks too).
  void _scheduleWake() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    if (_disposed) return;
    final next = [
      ?_store.snoozes.nextDue(),
      ?followUps.nextDue(),
    ].fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a);
    if (next == null) return;
    var delay = next.difference(DateTime.now());
    if (delay > const Duration(hours: 1)) delay = const Duration(hours: 1);
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    _wakeTimer = Timer(delay, onResume);
  }

  // ---------------------------------------------------------- follow-ups

  /// "Remind me if no reply" on sent mail, kept on this device.
  late final followUps = FollowUpReminders(_store);

  /// Whether [m] is mail the user sent (in Sent, or from one of their
  /// addresses) that can get a follow-up reminder.
  bool canFollowUp(StoredMessage m) {
    if (m.messageId == null) return false;
    final use = _store.mailboxes.byId(m.mailboxId)?.specialUse;
    if (use == SpecialUse.drafts || use == SpecialUse.trash) return false;
    if (use == SpecialUse.sent) return true;
    final from = m.from?.address.toLowerCase();
    return from != null && ownAddresses.any((a) => a.toLowerCase() == from);
  }

  /// The follow-up of [m], if one is set.
  FollowUp? followUpFor(StoredMessage m) {
    final id = m.messageId;
    return id == null ? null : followUps.find(id);
  }

  /// Sets (or changes) "Remind me if no reply" on [m], with Undo.
  void remindIfNoReply(StoredMessage m, DateTime due, String done) {
    if (!canFollowUp(m)) {
      onNotice?.call('Only mail you sent can remind you.');
      return;
    }
    final before = followUpFor(m);
    followUps.remind(followUps.forMessage(m, due));
    refresh();
    // Android: a background check at that time.
    unawaited(BackgroundMail.checkWhenDue(_store));
    onNotice?.call(
      done,
      undo: () {
        if (before == null) {
          followUps.cancel(m.messageId!);
        } else {
          followUps.restore(before);
        }
        refresh();
      },
    );
  }

  /// Ends a follow-up: "Cancel" while waiting, "Done" once it came back.
  /// With Undo.
  void endFollowUp(FollowUp f) {
    final ended = followUps.cancel(f.messageId);
    if (ended == null) return;
    refresh();
    onNotice?.call(
      ended.returned ? 'Marked done' : 'Reminder cancelled',
      undo: () {
        followUps.restore(ended);
        refresh();
      },
    );
  }

  /// Ends follow-ups that got a reply, and brings back those whose time
  /// came without one ("No reply yet", announced by [onFollowUpsBack]).
  /// Run after each sync, when the app comes to the foreground, and at
  /// the next due time.
  void checkFollowUps([DateTime? now]) {
    if (_disposed) return;
    try {
      final result = followUps.check(now: now);
      if (!result.isEmpty) refresh();
      if (result.returned.isNotEmpty) onFollowUpsBack?.call();
    } on Object catch (e) {
      debugPrint('follow-ups: ${e.runtimeType}');
    }
    _scheduleWake();
  }

  // --------------------------------------------------------- invitations

  /// The user's answers to invitations, remembered on the device.
  late final invitationAnswers = InvitationAnswers(_store);

  /// Changes when an answer is sent or undone, so the card updates.
  final invitationsChanged = ValueNotifier<int>(0);

  /// Every address of the user's accounts.
  List<String> get ownAddresses => [
    for (final a in _store.accounts.all()) a.email,
  ];

  /// The user among [invite]'s guests: the account it came to first,
  /// else any of their addresses. Null if they aren't on the list.
  CalendarPerson? ownAttendee(StoredMessage message, CalendarInvite invite) {
    final account = _store.accounts.byId(message.accountId);
    return (account == null ? null : invite.attendeeFor([account.email])) ??
        invite.attendeeFor(ownAddresses);
  }

  /// Sends the answer to the open invitation to its organizer (and no one
  /// else), through the outbox with Undo, and remembers it. Returns null
  /// on success, or why it couldn't be sent.
  String? answerInvitation(
    ReaderReady r,
    CalendarAnswer answer, {
    String? note,
  }) {
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
      pending = services.sender.send(draft);
    } on ComposeException {
      return 'The organizer\'s address isn\'t usable, so no answer was sent.';
    }
    services.worker.syncAt(pending.accountId, pending.undoUntil);
    final previous = invitationAnswers.of(invite);
    invitationAnswers.remember(invite, answer);
    invitationsChanged.value++;
    refresh();
    final organizer = invite.organizer!.label;
    onNotice?.call(
      switch (answer) {
        CalendarAnswer.accepted => 'Accepted. Telling $organizer…',
        CalendarAnswer.tentative => 'Answered maybe. Telling $organizer…',
        _ => 'Declined. Telling $organizer…',
      },
      undo: () {
        if (services.sender.cancel(pending)) {
          invitationAnswers.forget(invite, previous: previous);
          invitationsChanged.value++;
          refresh();
        } else {
          onNotice?.call('Too late to undo: your answer is on its way.');
        }
      },
    );
    return null;
  }

  // -------------------------------------------------------- read receipts

  /// For the user's own mail that asked for read receipts: the receipts
  /// so far (maybe none). Null when it didn't ask.
  List<ReadReceipt>? receiptsFor(StoredMessage message) {
    final id = message.messageId;
    if (id == null) return null;
    final account = _store.accounts.byId(message.accountId);
    final own =
        account != null &&
        message.from?.address.toLowerCase() == account.email.toLowerCase();
    if (!own) return null;
    final asked =
        _store.receipts.wasRequested(message.accountId, id) ||
        _store.messages
            .headers(message.id)
            .containsKey('disposition-notification-to');
    if (!asked) return null;
    return _store.receipts.forMessage(message.accountId, id);
  }

  // ------------------------------------------------------------ blocking

  /// The block that applies to [message]'s sender, if any.
  BlockedSender? blockFor(StoredMessage message) =>
      _store.blocks.matching(message.from?.address);

  /// Whether [message]'s sender can be blocked: it has one, and it isn't
  /// one of the user's own addresses. Cheap enough for a toolbar.
  bool canBlock(StoredMessage message) {
    final address = message.from?.address.toLowerCase();
    if (address == null || !address.contains('@')) return false;
    return !_store.accounts.all().any((a) => a.email.toLowerCase() == address);
  }

  /// How [message]'s sender can be blocked, with how much mail each
  /// choice would move; null if it can't be blocked.
  BlockChoice? blockChoice(StoredMessage message) {
    if (!canBlock(message)) return null;
    final address = message.from!.address.toLowerCase();
    final own = _store.accounts.all();
    final domain = Domains.registrable(
      address.substring(address.lastIndexOf('@') + 1),
    );
    final ownDomains = {
      for (final a in own)
        ?Domains.registrable(a.email.substring(a.email.lastIndexOf('@') + 1)),
    };
    final usableDomain =
        domain != null &&
        !FreeMail.isProvider(domain) &&
        !ownDomains.contains(domain);
    return BlockChoice(
      address: address,
      domain: usableDomain ? domain : null,
      fromAddress: _inboxesFrom(BlockKind.address, address).length,
      fromDomain: usableDomain
          ? _inboxesFrom(BlockKind.domain, domain).length
          : 0,
    );
  }

  List<StoredMessage> _inboxesFrom(BlockKind kind, String value) => [
    for (final account in _store.accounts.all())
      ...switch (kind) {
        BlockKind.address => _store.messages.inboxFromList(
          account.id,
          fromAddress: value,
        ),
        BlockKind.domain => _store.messages.inboxFromDomain(account.id, value),
      },
  ];

  /// Blocks [value]: new mail from it goes to Junk. With [moveExisting],
  /// its mail already in the inboxes goes too. Undo reverses both.
  void block(BlockKind kind, String value, {bool moveExisting = true}) {
    final existing = _store.blocks.all().any(
      (b) => b.kind == kind && b.value == value.toLowerCase(),
    );
    final blocked = _store.blocks.block(kind, value);
    void unblock() {
      if (!existing) _store.blocks.unblock(blocked.id);
      _refreshSelected();
    }

    final name = kind == BlockKind.domain
        ? 'everyone at ${blocked.value}'
        : blocked.value;
    final byAccount = <int, List<StoredMessage>>{};
    if (moveExisting) {
      for (final m in _inboxesFrom(kind, blocked.value)) {
        byAccount.putIfAbsent(m.accountId, () => []).add(m);
      }
    }
    final moves = [
      for (final MapEntry(key: accountId, value: messages) in byAccount.entries)
        if (SenderBlocker.destination(_store, accountId) case final target?)
          () => services.actions.move(messages, target),
    ];
    if (moves.isEmpty) {
      _refreshSelected();
      onNotice?.call('Blocked $name', undo: unblock);
      return;
    }
    final count = byAccount.values.fold(0, (sum, l) => sum + l.length);
    _remove(moves, 'Blocked $name. Moved $count to Junk.', alsoUndo: unblock);
  }

  void unblock(BlockedSender block) {
    _store.blocks.unblock(block.id);
    _refreshSelected();
    onNotice?.call(
      'Unblocked ${block.kind == BlockKind.domain ? 'everyone at ' : ''}${block.value}',
    );
  }

  // ------------------------------------------------------------ Screener

  /// First-time senders waiting in the Screener, in the inbox of
  /// [accountId] (or every inbox).
  List<WaitingSender> waitingSenders({int? accountId}) => _store.screener
      .waiting(accountIds: accountId == null ? null : [accountId]);

  /// The domain "everyone at …" choices offer for [address]: a company's
  /// own domain, never a free mail provider's or the user's own.
  String? screenerDomain(String address) {
    final lower = address.toLowerCase();
    final domain = Domains.registrable(
      lower.substring(lower.lastIndexOf('@') + 1),
    );
    if (domain == null || FreeMail.isProvider(domain)) return null;
    final own = {
      for (final a in _store.accounts.all())
        ?Domains.registrable(a.email.substring(a.email.lastIndexOf('@') + 1)),
    };
    return own.contains(domain) ? null : domain;
  }

  /// Lets [sender] in (or, with [wholeDomain], everyone at their domain):
  /// their mail goes to the Smart Inbox from now on. Offers Undo.
  void letIn(WaitingSender sender, {bool wholeDomain = false}) =>
      _screen(sender, ScreenerDecision.letIn, wholeDomain: wholeDomain);

  /// Screens [sender] out (or everyone at their domain): their mail goes
  /// where the user chose (Newsletters, Notifications or Archive), never
  /// deleted. Offers Undo.
  void screenOut(WaitingSender sender, {bool wholeDomain = false}) =>
      _screen(sender, ScreenerDecision.screenOut, wholeDomain: wholeDomain);

  void _screen(
    WaitingSender sender,
    ScreenerDecision decision, {
    required bool wholeDomain,
  }) {
    final screener = _store.screener;
    final domain = wholeDomain ? screenerDomain(sender.address) : null;
    final kind = domain == null ? ScreenerKind.address : ScreenerKind.domain;
    final value = domain ?? sender.address;
    final previous = screener.find(kind, value);
    final waiting = waitingSenders();
    final decided = screener.decide(kind, value, decision);
    void undo() => screener.restore(decided, previous);

    final who = domain == null
        ? (sender.name ?? sender.address)
        : 'Everyone at $domain';
    if (decision == ScreenerDecision.letIn) {
      refresh();
      onNotice?.call(
        '$who can now reach your inbox',
        undo: () {
          undo();
          refresh();
        },
      );
      return;
    }
    final place = screener.outPlace;
    if (place == ScreenOutPlace.archive) {
      // Their waiting mail goes now; later mail with each sync.
      final byAccount = <int, List<StoredMessage>>{};
      for (final w in waiting) {
        if (!decided.matches(w.address)) continue;
        for (final m in w.messages) {
          final archive = archiveFor(m);
          if (archive != null && archive.id != m.mailboxId) {
            byAccount.putIfAbsent(m.accountId, () => []).add(m);
          }
        }
      }
      final moves = [
        for (final MapEntry(key: accountId, value: group) in byAccount.entries)
          () => services.actions.move(group, _archiveFolder(accountId)!),
      ];
      if (moves.isNotEmpty) {
        _remove(moves, '$who screened out. Moved to Archive.', alsoUndo: undo);
        return;
      }
    }
    refresh();
    final where = switch (place) {
      ScreenOutPlace.newsletters => 'Newsletters',
      ScreenOutPlace.notifications => 'Notifications',
      ScreenOutPlace.archive => 'Archive',
    };
    onNotice?.call(
      '$who screened out. Their mail goes to $where.',
      undo: () {
        undo();
        refresh();
      },
    );
  }

  /// Folders a message can be moved to.
  List<StoredMailbox> moveTargets(StoredMessage m) => [
    for (final box in _store.mailboxes.forAccount(m.accountId))
      if (box.selectable && box.id != m.mailboxId && !box.isAppData) box,
  ];

  static String _folderName(StoredMailbox m) =>
      m.isInbox ? 'Inbox' : m.name.split(m.delimiter ?? '/').last;

  // ----------------------------------------------------------- composing

  /// A new message from the account being viewed (or the first account).
  void compose() {
    final accountId =
        location.value.accountId ?? _store.accounts.all().firstOrNull?.id;
    if (accountId != null) onCompose?.call(Draft(accountId: accountId));
  }

  /// A new message to a `mailto:` link's address (and subject, if given).
  void composeTo(Uri mailto) {
    final accountId =
        selected?.accountId ?? _store.accounts.all().firstOrNull?.id;
    if (accountId == null) return;
    final parsed = const AddressParser().parse(
      Uri.decodeComponent(mailto.path),
    );
    onCompose?.call(
      Draft(
        accountId: accountId,
        to: parsed.mailboxes,
        subject: mailto.queryParameters['subject'] ?? '',
      ),
    );
  }

  void reply(ReaderReady r) =>
      onCompose?.call(services.replies.reply(r.message, r.view));

  void replyAll(ReaderReady r) =>
      onCompose?.call(services.replies.replyAll(r.message, r.view));

  void forward(ReaderReady r) =>
      onCompose?.call(services.replies.forward(r.message, r.view));

  /// The open message exactly as the server sent it (stored when opened),
  /// or null if it is not on the device.
  Uint8List? rawMessage(StoredMessage message) =>
      _store.messages.body(message.id);

  /// Forward the whole message as an attached email.
  void forwardAsAttachment(ReaderReady r) {
    final raw = rawMessage(r.message);
    if (raw == null) return;
    onCompose?.call(services.replies.forwardAsAttachment(r.message, raw));
  }

  bool _isDraft(StoredMessage m) =>
      m.flags.draft &&
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.drafts;

  Future<void> _editDraft(StoredMessage message) async {
    try {
      if (_store.messages.body(message.id) == null) {
        await services.worker.loadBody(message.id);
      }
      final raw = _store.messages.body(message.id);
      if (raw == null || _disposed) return;
      onCompose?.call(services.drafts.fromDraftsFolder(message, raw));
    } on SyncWorkerException {
      onNotice?.call('Can\'t open the draft while offline.');
    } on BodyUnavailableException {
      onNotice?.call('This draft is no longer on the server.');
    }
  }

  // ------------------------------------------------------ custom folders

  /// Creates a folder on the server and opens it. Returns an error to
  /// show, or null on success.
  Future<String?> createFolder(int accountId, String name) async {
    try {
      final id = await services.worker.createFolder(accountId, name);
      if (!_disposed) {
        _refreshCounts();
        goTo(FolderLocation(id, accountId));
      }
      return null;
    } on ArgumentError catch (e) {
      return switch (e.message) {
        final String message when message.contains('separator') =>
          'Folder names can\'t contain "${message.split('"')[1]}" on this server.',
        final String message when message.contains('INBOX') =>
          'Inbox already exists.',
        _ => 'That can\'t be a folder name.',
      };
    } on SyncWorkerException catch (e) {
      return e.failure.kind == SyncFailureKind.network
          ? 'Folders can only be created while online.'
          : 'The server refused: ${e.failure.message}';
    }
  }

  /// Whether rules can move mail into [mailbox] (not the inbox, Drafts or
  /// Sent).
  bool canHaveRules(StoredMailbox mailbox) =>
      !mailbox.isInbox &&
      mailbox.selectable &&
      mailbox.specialUse != SpecialUse.drafts &&
      mailbox.specialUse != SpecialUse.sent;

  List<FolderRule> rulesFor(int mailboxId) =>
      _store.folderRules.forMailbox(mailboxId);

  /// Adds a rule; with [includeExisting] the inbox is filed with the next
  /// sync. Returns an error to show, or null.
  String? addRule(
    StoredMailbox mailbox,
    RuleField field,
    String value, {
    bool includeExisting = false,
  }) {
    try {
      _store.folderRules.add(
        accountId: mailbox.accountId,
        mailboxId: mailbox.id,
        field: field,
        value: value,
        includeExisting: includeExisting,
      );
    } on ArgumentError {
      return switch (field) {
        RuleField.fromAddress ||
        RuleField.toAddress => 'Enter an email address.',
        RuleField.fromDomain => 'Enter a domain, like example.com.',
        RuleField.subject => 'Enter some text.',
      };
    }
    if (includeExisting) services.worker.requestSync(mailbox.accountId);
    return null;
  }

  void removeRule(FolderRule rule) => _store.folderRules.remove(rule.id);

  // -------------------------------------------------------------- outbox

  /// Messages waiting to be sent or failed, oldest first.
  List<OutboxEntry> get outbox => _store.outbox.sends();

  void retrySend(OutboxEntry entry) {
    _store.outbox.retryFailed(entry.id);
    services.worker.requestSync(entry.accountId);
    refresh();
  }

  void discardSend(OutboxEntry entry) {
    _store.outbox.discardFailed(entry.id);
    refresh();
  }

  // ---------------------------------------------------------- send later

  /// Messages scheduled with "Send later".
  late final scheduledSends = ScheduledSends(_store, services.sender);

  static const _tooLate =
      'Too late to change: the message is already on its way.';

  /// Sends a scheduled message now (with Undo, which puts it back at its
  /// time).
  void sendScheduledNow(ScheduledSend s) {
    final now = SendLaterTimes.clock();
    final pending = scheduledSends.sendNow(s, now: now);
    if (pending != null) _followScheduled(s, pending, now);
    refresh();
    if (pending == null) {
      onNotice?.call(_tooLate);
      return;
    }
    services.worker.syncAt(pending.accountId, pending.undoUntil);
    onNotice?.call(
      'Sending…',
      undo: () {
        // Back to its time, unless it has started to go out.
        final undone =
            services.sender.cancel(pending, now: SendLaterTimes.clock()) &&
            _rescheduleDraft(pending.draft, s.at, from: pending);
        refresh();
        if (!undone) onNotice?.call('Too late: the message is on its way.');
      },
    );
  }

  bool _rescheduleDraft(Draft draft, DateTime at, {PendingSend? from}) {
    PendingSend pending;
    try {
      pending = services.sender.schedule(
        draft,
        at.toLocal(),
        now: SendLaterTimes.clock(),
      );
      _armScheduled(pending);
    } on ArgumentError {
      // Its time has come meanwhile: send it.
      pending = services.sender.send(draft, now: SendLaterTimes.clock());
      services.worker.syncAt(pending.accountId, pending.undoUntil);
    }
    if (from != null) {
      final sentAt = pending.scheduledFor ?? SendLaterTimes.clock();
      final before = followUps.find(from.messageId)?.sentAt;
      followUps.move(
        from.messageId,
        pending.messageId,
        shift: before == null ? Duration.zero : sentAt.difference(before),
      );
    }
    return true;
  }

  /// A scheduled message's follow-up goes with it when it goes out under
  /// a new Message-ID ([pending], sent at its time or [now]), keeping the
  /// time between sending and the reminder.
  void _followScheduled(ScheduledSend s, PendingSend pending, DateTime now) {
    final id = _scheduledId(s);
    if (id == null) return;
    final sentAt = pending.scheduledFor ?? now;
    followUps.move(id, pending.messageId, shift: sentAt.difference(s.at));
  }

  /// The Message-ID a scheduled message was to go out with.
  static String? _scheduledId(ScheduledSend s) {
    final data = s.entry.data;
    return data == null ? null : const MimeParser().parse(data).messageId;
  }

  /// Sends a scheduled message at [at] instead.
  void rescheduleSend(ScheduledSend s, DateTime at, String done) {
    final PendingSend? pending;
    final now = SendLaterTimes.clock();
    try {
      pending = scheduledSends.reschedule(s, at, now: now);
    } on ArgumentError {
      sendScheduledNow(s);
      return;
    }
    if (pending != null) _followScheduled(s, pending, now);
    refresh();
    if (pending == null) {
      onNotice?.call(_tooLate);
      return;
    }
    _armScheduled(pending);
    onNotice?.call(done);
  }

  /// Takes a scheduled message back to keep writing it (the schedule
  /// ends; closing the window keeps it as a draft).
  void editScheduled(ScheduledSend s) {
    final draft = scheduledSends.edit(s, now: SendLaterTimes.clock());
    // Not sent: no reminder for it.
    if (draft != null) followUps.cancel(_scheduledId(s) ?? '');
    refresh();
    if (draft == null) {
      onNotice?.call(_tooLate);
      return;
    }
    onCompose?.call(draft);
  }

  /// Doesn't send a scheduled message: it goes to Drafts instead.
  void cancelScheduled(ScheduledSend s) {
    final id = _scheduledId(s);
    final outcome = scheduledSends.cancel(s, now: SendLaterTimes.clock());
    if (outcome != null) followUps.cancel(id ?? '');
    refresh();
    if (outcome == null) {
      onNotice?.call(_tooLate);
      return;
    }
    services.worker.requestSync(s.entry.accountId);
    onNotice?.call(
      outcome == DraftOutcome.savedToServer
          ? 'It won\'t be sent. It\'s in Drafts.'
          : 'It won\'t be sent. It\'s kept as a draft on this device.',
    );
  }

  /// A sync at the scheduled time (and on Android, a background check).
  void _armScheduled(PendingSend pending) {
    services.worker.syncAt(pending.accountId, pending.undoUntil);
    if (pending.scheduledFor case final at?) {
      services.worker.syncAt(pending.accountId, at);
    }
    unawaited(BackgroundMail.checkWhenDue(_store));
  }

  // ---------------------------------------------------------------- sync

  SyncEvent? lastEvent(int accountId) => _lastEvent[accountId];

  Future<void> syncNow() async {
    try {
      await services.worker.syncNow();
    } on SyncWorkerException {
      // Shown through the account's failure event.
    }
  }

  void _onSyncEvent(SyncEvent event) {
    _lastEvent[event.accountId] = event;
    status.value = _computeStatus();
    if (event is AccountSynced) {
      tidyCodes();
      wakeSnoozes();
      checkFollowUps();
    }
    // Several events arrive close together: refresh once.
    _refreshSoon?.cancel();
    _refreshSoon = Timer(const Duration(milliseconds: 250), refresh);
  }

  SyncStatus _computeStatus() {
    if (_lastEvent.values.any((e) => e is AccountSyncStarted)) {
      return const SyncRunning();
    }
    for (final MapEntry(key: accountId, value: event) in _lastEvent.entries) {
      if (event is AccountSyncFailed) {
        final account = _store.accounts.byId(accountId);
        return SyncProblem(
          event.failure.kind,
          account?.email ?? '',
          accountId: accountId,
          oauth: account?.usesOAuth ?? false,
        );
      }
    }
    return SyncIdle(DateTime.now());
  }

  void dispose() {
    _disposed = true;
    _refreshSoon?.cancel();
    _wakeTimer?.cancel();
    unawaited(_events.cancel());
    list.dispose();
    location.dispose();
    counts.dispose();
    reader.dispose();
    selection.dispose();
    invitationsChanged.dispose();
    status.dispose();
    codesOffer.dispose();
  }
}

/// Top level, so [compute] sends only the bytes to the helper isolate.
(MessageView, TrustReport, UnsubscribePlan) _parseAndCheck(
  (Uint8List, TrustContext?) input,
) {
  final (raw, context) = input;
  final view = MessageView.parse(raw);
  final trust = context == null
      ? TrustReport.empty
      : const TrustChecker().check(view, context);
  return (view, trust, UnsubscribePlanner.plan(view.message, trust));
}
