// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_view/mail_view.dart';

import '../../../background/background_mail.dart';
import '../../../services/app_services.dart';
import '../../accounts/state/own_addresses.dart';
import '../../compose/state/compose_starter.dart';
import '../../compose/state/send_later_times.dart';
import '../../organise/state/blocking_controller.dart';
import '../../organise/state/folder_controller.dart';
import '../../organise/state/follow_up_controller.dart';
import '../../organise/state/old_codes_controller.dart';
import '../../organise/state/screener_controller.dart';
import '../../organise/state/snooze_controller.dart';
import '../../organise/state/unsubscribe_controller.dart';
import '../../organise/state/wake_timer.dart';
import '../../reader/state/invitation_answers.dart';
import '../../reader/state/reader_controller.dart';
import '../../reader/state/reader_state.dart';
import 'away_controller.dart';
import 'inbox_summary.dart';
import 'location_controller.dart';
import 'mail_counts.dart';
import 'mail_location.dart';
import 'message_actions.dart';
import 'message_list_model.dart';
import 'selection_controller.dart';
import 'sync_status.dart';

export '../../organise/state/blocking_controller.dart' show BlockChoice;
export '../../reader/state/reader_state.dart'
    show ReaderEmpty, ReaderFailed, ReaderLoading, ReaderReady, ReaderState;
export 'mail_counts.dart' show MailCounts;
export 'sync_status.dart' show SyncIdle, SyncProblem, SyncRunning, SyncStatus;

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
      followUps = FollowUpReminders(services.store),
      syncStatus = SyncStatusController(services.store, services.worker) {
    countsController = CountsController(_store, list, followUps);
    composeStarter = ComposeStarter(
      services,
      accountInView: () => location.value.accountId,
      notify: _notify,
    );
    readerController = ReaderController(
      services,
      list,
      countsController,
      composeStarter,
      refresh: refresh,
    );
    selectionController = SelectionController(
      _store,
      list,
      openMessage: () => readerController.selected,
    );
    locationController = LocationController(
      _store,
      services.worker,
      list,
      selectionController,
      refresh: refresh,
    );
    messageActions = MessageActions(
      services,
      list,
      locationController,
      selectionController,
      readerController,
      refresh: refresh,
      notify: _notify,
    );
    folderController = FolderController(
      _store,
      services.worker,
      locationController,
      countsController,
    );
    wakeTimer = WakeTimer(_store, followUps, onDue: _wakeDue);
    snoozeController = SnoozeController(
      services,
      list,
      locationController,
      selectionController,
      readerController,
      messageActions,
      wakeTimer,
      refresh: refresh,
      notify: _notify,
    );
    followUpController = FollowUpController(
      _store,
      followUps,
      wakeTimer,
      refresh: refresh,
      notify: _notify,
    );
    awayController = AwayController(
      services.worker,
      list,
      messageActions,
      snoozeController,
      followUpController,
      refresh: refresh,
      notify: _notify,
    );
    oldCodesController = OldCodesController(
      CodeCleaner(_store, services.actions),
      services.worker,
      readerController,
      selectionController,
      refresh: refresh,
      notify: _notify,
    );
    unsubscribeController = UnsubscribeController(
      services,
      readerController,
      messageActions,
      notify: _notify,
    );
    blockingController = BlockingController(
      _store,
      services.actions,
      messageActions,
      readerController,
      notify: _notify,
    );
    screenerController = ScreenerController(
      _store,
      services.actions,
      messageActions,
      refresh: refresh,
      notify: _notify,
    );
    syncStatus.onEvent = _onSyncEvent;
    // Stored mail sorted again after start-up: sections change.
    services.resorted.addListener(refresh);
    // What arrived since the app was last used (closed, or in the
    // background) is "New since you were away".
    list.away.cameBack();
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

  /// Where the user is, and loading more of its list.
  late final LocationController locationController;
  ValueNotifier<MailLocation> get location => locationController.location;

  /// Sidebar and section counts.
  late final CountsController countsController;
  ValueNotifier<MailCounts> get counts => countsController.counts;

  /// The open message.
  late final ReaderController readerController;
  ValueNotifier<ReaderState> get reader => readerController.reader;

  /// New messages, replies, forwards and drafts in the compose window.
  late final ComposeStarter composeStarter;

  /// Pin, read, archive, move and delete, with Undo.
  late final MessageActions messageActions;

  /// Creating folders, and their rules.
  late final FolderController folderController;

  /// When snoozed mail and follow-ups are next due.
  late final WakeTimer wakeTimer;

  /// Snoozing mail and bringing it back.
  late final SnoozeController snoozeController;

  /// "Remind me if no reply".
  late final FollowUpController followUpController;

  /// Leaving the app and coming back ("New since you were away").
  late final AwayController awayController;

  /// Tidying up old verification codes.
  late final OldCodesController oldCodesController;

  /// Unsubscribing from mailing lists.
  late final UnsubscribeController unsubscribeController;

  /// Blocking senders.
  late final BlockingController blockingController;

  /// The Screener's first-time senders.
  late final ScreenerController screenerController;

  /// Messages picked for a bulk action.
  late final SelectionController selectionController;
  ValueNotifier<Set<int>> get selection => selectionController.selection;

  /// The sync worker's events and the status line.
  final SyncStatusController syncStatus;
  ValueNotifier<SyncStatus> get status => syncStatus.status;

  /// Moves old verification codes out of the inbox, once agreed.
  CodeCleaner get codeCleaner => oldCodesController.codeCleaner;

  /// Whether the Verification section asks to tidy up old codes.
  ValueNotifier<bool> get codesOffer => oldCodesController.codesOffer;

  /// The summary line at the top of the inbox (made when first shown).
  InboxSummary get summary => _summary ??= InboxSummary(services, list);
  InboxSummary? _summary;

  Timer? _refreshSoon;
  bool _disposed = false;

  MailStore get _store => services.store;

  StoredMessage? get selected => readerController.selected;

  /// Opens the compose window (set by the screen that can show it).
  void Function(Draft draft)? get onCompose => composeStarter.onCompose;
  set onCompose(void Function(Draft draft)? value) =>
      composeStarter.onCompose = value;

  /// Tells the user something; with [undo], offers to take it back.
  void Function(String message, {VoidCallback? undo})? onNotice;

  /// What the focused controllers call to tell the user something.
  void _notify(String message, {VoidCallback? undo}) =>
      onNotice?.call(message, undo: undo);

  /// Asks for an account's new password or sign-in (set by the screen
  /// that can show it).
  void Function(Account account)? get onReconnect => syncStatus.onReconnect;
  set onReconnect(void Function(Account account)? value) =>
      syncStatus.onReconnect = value;

  /// Announces snoozed mail that came back (set by the screen that can
  /// post notifications).
  void Function(BackFromSnooze back)? get onBackFromSnooze =>
      snoozeController.onBackFromSnooze;
  set onBackFromSnooze(void Function(BackFromSnooze back)? value) =>
      snoozeController.onBackFromSnooze = value;

  /// Announces sent mail back with "No reply yet" (set by the screen that
  /// can post notifications).
  void Function()? get onFollowUpsBack => followUpController.onFollowUpsBack;
  set onFollowUpsBack(void Function()? value) =>
      followUpController.onFollowUpsBack = value;

  /// Fixes the login of the account in [status], if that is the problem.
  void reconnect(SyncProblem problem) => syncStatus.reconnect(problem);

  // ------------------------------------------------------------ location

  void goTo(MailLocation target) => locationController.goTo(target);

  void search(String text) => locationController.search(text);

  /// Searches for exactly what was typed, without correcting typos.
  void searchExactly(String text) => locationController.searchExactly(text);

  // --------------------------------------------------------------- lists

  /// Shows more of a flat list: stored messages first, then older mail
  /// from the server.
  Future<void> loadMore() => locationController.loadMore();

  /// Re-reads the list, the counts and the open message.
  void refresh() {
    if (_disposed) return;
    list.refresh();
    _refreshCounts();
    _refreshSelected();
    _refreshCodesOffer();
    wakeTimer.schedule();
  }

  void _refreshCounts() => countsController.refresh();

  // ---------------------------------------------------------- old codes

  void _refreshCodesOffer() => oldCodesController.refreshOffer();

  /// After a sync: moves old codes out of the inbox (at most once an hour,
  /// once the user agreed), and says so with Undo. The open message and
  /// selected ones stay.
  void tidyCodes([DateTime? now]) => oldCodesController.tidy(now);

  /// "Turn on" in the Verification section: agrees, and tidies up now.
  void agreeToTidyCodes() => oldCodesController.agree();

  /// "Not now": asked again in a month.
  void declineTidyCodes() => oldCodesController.decline();

  // -------------------------------------------------------------- reader

  /// Opens [message]: marks it read and shows it, downloading it first if
  /// needed. Drafts open in the compose window instead.
  Future<void> open(StoredMessage message) => readerController.open(message);

  /// [message] read and checked, as the reading pane shows it, without
  /// opening it (it stays unread): downloads it first if needed. Throws
  /// [BodyUnavailableException] or [SyncWorkerException].
  Future<ReaderReady> readerFor(StoredMessage message) =>
      readerController.readerFor(message);

  /// When the user unsubscribed from [message]'s list, if they did.
  Unsubscription? unsubscriptionFor(StoredMessage message) =>
      readerController.unsubscriptionFor(message);

  void closeMessage() => readerController.close();

  // -------------------------------------------------------------- images

  /// Loads the open message's images; with [always], also for later mail
  /// from this sender (only offered when the server verified the sender).
  void showImages(ReaderReady r, {bool always = false}) =>
      readerController.showImages(r, always: always);

  // --------------------------------------------------------- unsubscribe

  /// Inbox mail from the same list as [r] (to offer archiving it).
  List<StoredMessage> sameList(ReaderReady r) =>
      unsubscribeController.sameList(r);

  /// Unsubscribes with [method]. One-click requests go out now; an email
  /// goes through the outbox (so it also works offline). For a web page
  /// the caller opens it and then calls this to remember it. Returns null
  /// on success, or why it failed.
  Future<String?> unsubscribe(
    ReaderReady r,
    UnsubscribeMethod method, {
    bool archiveList = false,
  }) => unsubscribeController.unsubscribe(r, method, archiveList: archiveList);

  /// Opens the message after (or before) the open one in the list.
  void openNext({bool previous = false}) =>
      readerController.openNext(previous: previous);

  void _refreshSelected() => readerController.refreshOpen();

  // ----------------------------------------------------------- selection

  bool get selecting => selectionController.selecting;

  void toggleSelected(StoredMessage m) => selectionController.toggle(m);

  /// Selects from the last selected message to [m] (Shift-click).
  void selectRange(StoredMessage m) => selectionController.selectRange(m);

  void selectAllVisible() => selectionController.selectAllVisible();

  void clearSelection() => selectionController.clear();

  /// The selected messages, or else the open one.
  List<StoredMessage> get targets => selectionController.targets;

  // ------------------------------------------------------------- actions

  void togglePin(List<StoredMessage> messages) =>
      messageActions.togglePin(messages);

  void toggleRead(List<StoredMessage> messages) =>
      messageActions.toggleRead(messages);

  void markSectionRead(SmartSection section) =>
      messageActions.markSectionRead(section);

  /// The account's Archive folder, if it has one. On Gmail, archiving
  /// means moving to All Mail (the message leaves the inbox, nothing else).
  StoredMailbox? archiveFor(StoredMessage m) => messageActions.archiveFor(m);

  bool isInTrash(StoredMessage m) => messageActions.isInTrash(m);

  /// Whether deleting [m] removes it for good: it is in Trash, or its
  /// account has no Trash folder (the server then deletes it at once).
  bool deletesForever(StoredMessage m) => messageActions.deletesForever(m);

  bool isInJunk(StoredMessage m) => messageActions.isInJunk(m);

  /// "Not spam": back to each account's inbox. Moving mail out of Spam is
  /// how Gmail and other providers learn it isn't spam.
  void notSpam(List<StoredMessage> messages) =>
      messageActions.notSpam(messages);

  /// Archives into each account's Archive folder (skipping messages already
  /// there or in accounts without one).
  void archive(List<StoredMessage> messages, {String? done}) =>
      messageActions.archive(messages, done: done);

  void moveTo(List<StoredMessage> messages, StoredMailbox target) =>
      messageActions.moveTo(messages, target);

  /// Moves to Trash (or deletes for good when already in Trash, or the
  /// account has none; the caller confirms that).
  void delete(List<StoredMessage> messages) => messageActions.delete(messages);

  /// "Always move mail from this sender here", then moves this message.
  void moveAlways(StoredMessage message, StoredMailbox target) =>
      messageActions.moveAlways(message, target);

  // -------------------------------------------------------------- snooze

  /// Whether [m] can be snoozed: inbox mail with a Message-ID (what keeps
  /// it the same message on every device).
  bool canSnooze(StoredMessage m) => snoozeController.canSnooze(m);

  /// When [m] comes back, while it is snoozed.
  DateTime? snoozedUntil(StoredMessage m) => snoozeController.snoozedUntil(m);

  /// Snoozes [messages] until [until] (or changes when they come back),
  /// says [done], and offers Undo. They leave the inbox now; nothing
  /// changes on the mail server.
  void snooze(List<StoredMessage> messages, DateTime until, String done) =>
      snoozeController.snooze(messages, until, done);

  /// Brings [messages] back now, where they were in the inbox (not as
  /// new), with Undo.
  void unsnooze(List<StoredMessage> messages) =>
      snoozeController.unsnooze(messages);

  /// Brings back snoozed mail whose time came (or that got a reply),
  /// marked unread, and announces it ([onBackFromSnooze]). Run after each
  /// sync, when the app comes to the foreground, and at the next due time.
  void wakeSnoozes([DateTime? now]) => snoozeController.wake(now);

  /// The app went to the background (or is closing): remembered for "New
  /// since you were away", also if the app is then closed.
  void onHide() => awayController.onHide();

  /// Coming back to the app: a look for new mail at once (a sign-in code
  /// is often why someone switches back), then snoozed mail and
  /// follow-ups that are due. After a minute away the mail connections
  /// may have died quietly, so they are opened afresh.
  void onResume() => awayController.onResume();

  /// Snoozed mail and follow-ups whose time came.
  void _wakeDue() {
    wakeSnoozes();
    checkFollowUps();
  }

  /// How long the app can be away before [onResume] reconnects.
  static const awayBeforeReconnect = AwayController.awayBeforeReconnect;

  // ------------------------------------------------ new since you were away

  /// "Done" on "New since you were away": its messages go back to their
  /// sections, still unread (only a view; nothing changes on the server).
  void doneWithAway() => awayController.doneWithAway();

  /// "Mark all as read" on "New since you were away".
  void markAwayRead() => awayController.markAwayRead();

  // ---------------------------------------------------------- follow-ups

  /// "Remind me if no reply" on sent mail, kept on this device.
  final FollowUpReminders followUps;

  /// Whether [m] is mail the user sent (in Sent, or from one of their
  /// addresses) that can get a follow-up reminder.
  bool canFollowUp(StoredMessage m) => followUpController.canFollowUp(m);

  /// The follow-up of [m], if one is set.
  FollowUp? followUpFor(StoredMessage m) => followUpController.followUpFor(m);

  /// Sets (or changes) "Remind me if no reply" on [m], with Undo.
  void remindIfNoReply(StoredMessage m, DateTime due, String done) =>
      followUpController.remindIfNoReply(m, due, done);

  /// Ends a follow-up: "Cancel" while waiting, "Done" once it came back.
  /// With Undo.
  void endFollowUp(FollowUp f) => followUpController.endFollowUp(f);

  /// Ends follow-ups that got a reply, and brings back those whose time
  /// came without one ("No reply yet", announced by [onFollowUpsBack]).
  /// Run after each sync, when the app comes to the foreground, and at
  /// the next due time.
  void checkFollowUps([DateTime? now]) => followUpController.check(now);

  // ------------------------------------------------------------ accounts

  /// Changes when the accounts' order changes, so the sidebar follows.
  final accountsChanged = ValueNotifier<int>(0);

  /// Puts the accounts in the order of [ids]: the sidebar, the From
  /// choice and new messages (from the top account) follow it.
  void reorderAccounts(List<int> ids) {
    _store.accounts.reorder(ids);
    accountsChanged.value++;
  }

  // --------------------------------------------------------- invitations

  /// The user's answers to invitations, remembered on the device.
  late final invitationAnswers = InvitationAnswers(_store);

  /// Changes when an answer is sent or undone, so the card updates.
  final invitationsChanged = ValueNotifier<int>(0);

  /// Every address of the user's accounts.
  List<String> get ownAddresses => _store.ownAddresses;

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
  List<ReadReceipt>? receiptsFor(StoredMessage message) =>
      readerController.receiptsFor(message);

  // ------------------------------------------------------------ blocking

  /// The block that applies to [message]'s sender, if any.
  BlockedSender? blockFor(StoredMessage message) =>
      blockingController.blockFor(message);

  /// Whether [message]'s sender can be blocked: it has one, and it isn't
  /// one of the user's own addresses. Cheap enough for a toolbar.
  bool canBlock(StoredMessage message) => blockingController.canBlock(message);

  /// How [message]'s sender can be blocked, with how much mail each
  /// choice would move; null if it can't be blocked.
  BlockChoice? blockChoice(StoredMessage message) =>
      blockingController.blockChoice(message);

  /// Blocks [value]: new mail from it goes to Junk. With [moveExisting],
  /// its mail already in the inboxes goes too. Undo reverses both.
  void block(BlockKind kind, String value, {bool moveExisting = true}) =>
      blockingController.block(kind, value, moveExisting: moveExisting);

  void unblock(BlockedSender block) => blockingController.unblock(block);

  // ------------------------------------------------------------ Screener

  /// First-time senders waiting in the Screener, in the inbox of
  /// [accountId] (or every inbox).
  List<WaitingSender> waitingSenders({int? accountId}) =>
      screenerController.waitingSenders(accountId: accountId);

  /// Whether [m] comes from someone the Screener would hold back if it
  /// were on: the only email on the device from them, someone the user
  /// never wrote to, and not one of the user's own addresses. False while
  /// the Screener is on (it decides then).
  bool isFirstTimeSender(StoredMessage m) =>
      screenerController.isFirstTimeSender(m);

  /// The domain "everyone at …" choices offer for [address]: a company's
  /// own domain, never a free mail provider's or the user's own.
  String? screenerDomain(String address) =>
      screenerController.screenerDomain(address);

  /// Lets [sender] in (or, with [wholeDomain], everyone at their domain):
  /// their mail goes to the Smart Inbox from now on. Offers Undo.
  void letIn(WaitingSender sender, {bool wholeDomain = false}) =>
      screenerController.letIn(sender, wholeDomain: wholeDomain);

  /// Screens [sender] out (or everyone at their domain): their mail goes
  /// where the user chose (Newsletters, Notifications or Archive), never
  /// deleted. Offers Undo.
  void screenOut(WaitingSender sender, {bool wholeDomain = false}) =>
      screenerController.screenOut(sender, wholeDomain: wholeDomain);

  /// Folders a message can be moved to.
  List<StoredMailbox> moveTargets(StoredMessage m) =>
      folderController.moveTargets(m);

  // ----------------------------------------------------------- composing

  /// A new message from the account being viewed (or the first account).
  void compose() {
    composeStarter.compose();
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

  void reply(ReaderReady r) => composeStarter.reply(r);

  void replyAll(ReaderReady r) => composeStarter.replyAll(r);

  void forward(ReaderReady r) => composeStarter.forward(r);

  /// The open message exactly as the server sent it (stored when opened),
  /// or null if it is not on the device.
  Uint8List? rawMessage(StoredMessage message) =>
      composeStarter.rawMessage(message);

  /// Forward the whole message as an attached email.
  void forwardAsAttachment(ReaderReady r) =>
      composeStarter.forwardAsAttachment(r);

  // ------------------------------------------------------ custom folders

  /// Creates a folder on the server and opens it. Returns an error to
  /// show, or null on success.
  Future<String?> createFolder(int accountId, String name) =>
      folderController.createFolder(accountId, name);

  /// Whether rules can move mail into [mailbox] (not the inbox, Drafts or
  /// Sent).
  bool canHaveRules(StoredMailbox mailbox) =>
      FolderController.canHaveRules(mailbox);

  List<FolderRule> rulesFor(int mailboxId) =>
      folderController.rulesFor(mailboxId);

  /// Adds a rule; with [includeExisting] the inbox is filed with the next
  /// sync. Returns an error to show, or null.
  String? addRule(
    StoredMailbox mailbox,
    RuleField field,
    String value, {
    bool includeExisting = false,
  }) => folderController.addRule(
    mailbox,
    field,
    value,
    includeExisting: includeExisting,
  );

  void removeRule(FolderRule rule) => folderController.removeRule(rule);

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

  SyncEvent? lastEvent(int accountId) => syncStatus.lastEvent(accountId);

  Future<void> syncNow() => syncStatus.syncNow();

  /// After each sync event (the status line is up to date by then).
  void _onSyncEvent(SyncEvent event) {
    if (event is AccountSynced) {
      tidyCodes();
      wakeSnoozes();
      checkFollowUps();
    }
    // Several events arrive close together: refresh once.
    _refreshSoon?.cancel();
    _refreshSoon = Timer(const Duration(milliseconds: 250), refresh);
  }

  void dispose() {
    _disposed = true;
    _refreshSoon?.cancel();
    wakeTimer.dispose();
    snoozeController.dispose();
    followUpController.dispose();
    syncStatus.dispose();
    services.resorted.removeListener(refresh);
    _summary?.dispose();
    list.dispose();
    locationController.dispose();
    countsController.dispose();
    readerController.dispose();
    composeStarter.dispose();
    folderController.dispose();
    selectionController.dispose();
    invitationsChanged.dispose();
    accountsChanged.dispose();
    oldCodesController.dispose();
  }
}
