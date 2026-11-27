// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_unsubscribe/mail_unsubscribe.dart';
import 'package:mail_view/mail_view.dart';

import '../../../background/background_mail.dart';
import '../../../core/state/validation.dart';
import '../../../services/app_services.dart';
import '../../accounts/state/account_order.dart';
import '../../accounts/state/own_addresses.dart';
import '../../compose/state/compose_fields.dart';
import '../../compose/state/compose_starter.dart';
import '../../compose/state/outbox_controller.dart';
import '../../organise/state/blocking_controller.dart';
import '../../organise/state/folder_controller.dart';
import '../../organise/state/follow_up_controller.dart';
import '../../organise/state/old_codes_controller.dart';
import '../../organise/state/screener_controller.dart';
import '../../organise/state/snooze_controller.dart';
import '../../organise/state/unsubscribe_controller.dart';
import '../../organise/state/wake_timer.dart';
import '../../reader/state/invitation_answers.dart';
import '../../reader/state/invitation_controller.dart';
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

/// The mail screen's state, as one object for the screens to hold.
///
/// It makes the focused controllers below, wires them together and keeps
/// the screen's API by handing each call to the one whose job it is. Each
/// part of the screen rebuilds only when its own data changes:
///
/// - [location]: where the user is ([locationController]);
/// - [list]: what the list shows (paged; index reads only);
/// - [counts]: sidebar and section counts ([countsController]);
/// - [reader]: the open message ([readerController]);
/// - [selection]: messages picked for a bulk action
///   ([selectionController]);
/// - [status]: sync status ([syncStatusController]).
///
/// The controllers depend on each other one way only (see
/// docs/architecture.md); what goes back up is a callback: [refresh] to
/// re-read the screen, [onNotice] to tell the user something.
final class MailController {
  MailController(this.services)
    : list = MessageListModel(services.store),
      followUps = FollowUpReminders(services.store),
      syncStatusController = SyncStatusController(
        services.store,
        services.worker,
      ) {
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
      messageActions,
      readerController,
      notify: _notify,
    );
    screenerController = ScreenerController(
      _store,
      messageActions,
      refresh: refresh,
      notify: _notify,
    );
    invitationController = InvitationController(
      services,
      refresh: refresh,
      notify: _notify,
    );
    outboxController = OutboxController(
      services,
      followUps,
      composeStarter,
      refresh: refresh,
      notify: _notify,
    );
    accountOrder = AccountOrder(_store);
    syncStatusController.onEvent = _onSyncEvent;

    // Stored mail sorted again after start-up: sections change.
    services.resorted.addListener(refresh);
    // What arrived since the app was last used (closed, or in the
    // background) is "New since you were away".
    list.away.cameBack();
    list.show(location.value);
    countsController.refresh();
    oldCodesController.refreshOffer();
    wakeSnoozes();
    checkFollowUps();
    // Android: a background check when the next scheduled message (or
    // follow-up) is due.
    unawaited(BackgroundMail.checkWhenDue(_store));
  }

  final AppServices services;
  final MessageListModel list;

  /// "Remind me if no reply" on sent mail, kept on this device.
  final FollowUpReminders followUps;

  // The focused controllers, in the order they are made: each takes only
  // those above it. The compose starter reads the location through a
  // callback.

  /// The sync worker's events and the status line.
  final SyncStatusController syncStatusController;

  /// Sidebar and section counts.
  late final CountsController countsController;

  /// New messages, replies, forwards and drafts in the compose window.
  late final ComposeStarter composeStarter;

  /// The open message, its images and read receipts.
  late final ReaderController readerController;

  /// Messages picked for a bulk action.
  late final SelectionController selectionController;

  /// Where the user is, and loading more of its list.
  late final LocationController locationController;

  /// Pin, read, archive, move and delete, with Undo.
  late final MessageActions messageActions;

  /// Creating folders, where mail can move, and folder rules.
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

  /// Answering calendar invitations.
  late final InvitationController invitationController;

  /// Failed and scheduled sends.
  late final OutboxController outboxController;

  /// The accounts' order.
  late final AccountOrder accountOrder;

  ValueNotifier<MailLocation> get location => locationController.location;
  ValueNotifier<MailCounts> get counts => countsController.counts;
  ValueNotifier<ReaderState> get reader => readerController.reader;
  ValueNotifier<Set<MessageId>> get selection => selectionController.selection;
  ValueNotifier<SyncStatus> get status => syncStatusController.status;

  /// While an action on thousands of messages runs in steps: what it
  /// does and how far it got ("Moving to Trash… 2,400 of 7,080").
  ValueNotifier<String?> get working => messageActions.working;

  /// Moves old verification codes out of the inbox, once agreed.
  CodeCleaner get codeCleaner => oldCodesController.codeCleaner;

  /// Whether the Verification section asks to tidy up old codes.
  ValueNotifier<bool> get codesOffer => oldCodesController.codesOffer;

  /// The summary line at the top of the inbox (made when first shown).
  InboxSummary get summary => _summary ??= InboxSummary(services, list);
  InboxSummary? _summary;

  Timer? _refreshSoon;
  bool _disposed = false;

  /// How many times the screen was read again ([refresh]), for tests that
  /// check an idle app stays quiet.
  @visibleForTesting
  int refreshes = 0;

  /// Sync events close together are read in one refresh, this long after
  /// the first.
  static const refreshDelay = Duration(milliseconds: 250);

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
  void Function(Account account)? get onReconnect =>
      syncStatusController.onReconnect;
  set onReconnect(void Function(Account account)? value) =>
      syncStatusController.onReconnect = value;

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
  void reconnect(SyncProblem problem) =>
      syncStatusController.reconnect(problem);

  // ------------------------------------------------------------ location

  void goTo(MailLocation target) => locationController.goTo(target);

  void search(String text) => locationController.search(text);

  /// Searches for exactly what was typed, without correcting typos.
  void searchExactly(String text) => locationController.searchExactly(text);

  /// Searches all of [accountId]'s mail on its server, for the search on
  /// screen.
  Future<void> searchOnServer(AccountId accountId) =>
      locationController.searchOnServer(accountId);

  // --------------------------------------------------------------- lists

  /// Shows more of a flat list: stored messages first, then older mail
  /// from the server.
  Future<void> loadMore() => locationController.loadMore();

  /// Re-reads the list, the counts and the open message. The list, the
  /// counts and the summary line tell their listeners only when what they
  /// show changed; the open message too when [quiet] (after a sync).
  void refresh({bool quiet = false}) {
    if (_disposed) return;
    refreshes++;
    list.refresh();
    // A setting the line follows may have changed without the list.
    _summary?.update();
    countsController.refresh();
    readerController.refreshOpen(quiet: quiet);
    oldCodesController.refreshOffer();
    wakeTimer.schedule();
  }

  // ---------------------------------------------------------- old codes

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

  /// Opens the message after (or before) the open one in the list.
  void openNext({bool previous = false}) =>
      readerController.openNext(previous: previous);

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
  ValueNotifier<int> get accountsChanged => accountOrder.changed;

  /// Puts the accounts in the order of [ids]: the sidebar, the From
  /// choice and new messages (from the top account) follow it.
  void reorderAccounts(List<AccountId> ids) => accountOrder.reorder(ids);

  // --------------------------------------------------------- invitations

  /// The user's answers to invitations, remembered on the device.
  InvitationAnswers get invitationAnswers => invitationController.answers;

  /// Changes when an answer is sent or undone, so the card updates.
  ValueNotifier<int> get invitationsChanged => invitationController.changed;

  /// Every address of the user's accounts.
  List<String> get ownAddresses => _store.ownAddresses;

  /// The user among [invite]'s guests: the account it came to first,
  /// else any of their addresses. Null if they aren't on the list.
  CalendarPerson? ownAttendee(StoredMessage message, CalendarInvite invite) =>
      invitationController.ownAttendee(message, invite);

  /// Sends the answer to the open invitation to its organizer (and no one
  /// else), through the outbox with Undo, and remembers it. Returns null
  /// on success, or why it couldn't be sent.
  String? answerInvitation(
    ReaderReady r,
    CalendarAnswer answer, {
    String? note,
  }) => invitationController.answer(r, answer, note: note);

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
  List<WaitingSender> waitingSenders({AccountId? accountId}) =>
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

  // ----------------------------------------------------------- composing

  /// A new message from the account being viewed (or the first account).
  void compose() => composeStarter.compose();

  /// A new message to a `mailto:` link's address (and subject, if given).
  void composeTo(Uri mailto) {
    final accountId =
        selected?.accountId ?? _store.accounts.all().firstOrNull?.id;
    if (accountId == null) return;
    switch (MailtoLink.parse(mailto)) {
      case Valid(value: final link):
        onCompose?.call(
          Draft(accountId: accountId, to: link.to, subject: link.subject),
        );
      case Invalid(:final reason):
        onNotice?.call(reason);
    }
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
  Future<String?> createFolder(AccountId accountId, String name) =>
      folderController.createFolder(accountId, name);

  /// Whether rules can move mail into [mailbox] (not the inbox, Drafts or
  /// Sent).
  bool canHaveRules(StoredMailbox mailbox) =>
      FolderController.canHaveRules(mailbox);

  List<FolderRule> rulesFor(MailboxId mailboxId) =>
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

  /// Folders a message can be moved to.
  List<StoredMailbox> moveTargets(StoredMessage m) =>
      folderController.moveTargets(m);

  // -------------------------------------------------------------- outbox

  /// Messages waiting to be sent or failed, oldest first.
  List<OutboxEntry> get outbox => outboxController.outbox;

  void retrySend(OutboxEntry entry) => outboxController.retrySend(entry);

  void discardSend(OutboxEntry entry) => outboxController.discardSend(entry);

  // ---------------------------------------------------------- send later

  /// Messages scheduled with "Send later".
  ScheduledSends get scheduledSends => outboxController.scheduledSends;

  /// Sends a scheduled message now (with Undo, which puts it back at its
  /// time).
  void sendScheduledNow(ScheduledSend s) =>
      outboxController.sendScheduledNow(s);

  /// Sends a scheduled message at [at] instead.
  void rescheduleSend(ScheduledSend s, DateTime at, String done) =>
      outboxController.rescheduleSend(s, at, done);

  /// Takes a scheduled message back to keep writing it (the schedule
  /// ends; closing the window keeps it as a draft).
  void editScheduled(ScheduledSend s) => outboxController.editScheduled(s);

  /// Doesn't send a scheduled message: it goes to Drafts instead.
  void cancelScheduled(ScheduledSend s) => outboxController.cancelScheduled(s);

  // ---------------------------------------------------------------- sync

  SyncEvent? lastEvent(AccountId accountId) =>
      syncStatusController.lastEvent(accountId);

  Future<void> syncNow() => syncStatusController.syncNow();

  /// After each sync event (the status line is up to date by then).
  void _onSyncEvent(SyncEvent event) {
    if (event is AccountSynced) {
      tidyCodes();
      wakeSnoozes();
      checkFollowUps();
    }
    // A sync starting changes nothing stored yet.
    if (event is AccountSyncStarted) return;
    // Several events arrive close together: refresh once, a little after
    // the first (later ones don't push it back, so a busy sync still
    // shows new mail).
    _refreshSoon ??= Timer(refreshDelay, () {
      _refreshSoon = null;
      refresh(quiet: true);
    });
  }

  /// Stops what can still call in (timers, sync events, the sorter),
  /// then disposes the controllers, those that use others first.
  void dispose() {
    _disposed = true;
    _refreshSoon?.cancel();
    wakeTimer.dispose();
    syncStatusController.dispose();
    services.resorted.removeListener(refresh);
    invitationController.dispose();
    accountOrder.dispose();
    oldCodesController.dispose();
    followUpController.dispose();
    snoozeController.dispose();
    folderController.dispose();
    locationController.dispose();
    selectionController.dispose();
    readerController.dispose();
    composeStarter.dispose();
    countsController.dispose();
    _summary?.dispose();
    list.dispose();
  }
}
