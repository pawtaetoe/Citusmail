// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/features/compose/state/compose_starter.dart';
import 'package:citusmail/src/features/inbox/state/away_controller.dart';
import 'package:citusmail/src/features/inbox/state/location_controller.dart';
import 'package:citusmail/src/features/inbox/state/mail_counts.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/state/message_actions.dart';
import 'package:citusmail/src/features/inbox/state/message_list_model.dart';
import 'package:citusmail/src/features/inbox/state/selection_controller.dart';
import 'package:citusmail/src/features/organise/state/blocking_controller.dart';
import 'package:citusmail/src/features/organise/state/follow_up_controller.dart';
import 'package:citusmail/src/features/organise/state/old_codes_controller.dart';
import 'package:citusmail/src/features/organise/state/screener_controller.dart';
import 'package:citusmail/src/features/organise/state/snooze_controller.dart';
import 'package:citusmail/src/features/organise/state/unsubscribe_controller.dart';
import 'package:citusmail/src/features/organise/state/wake_timer.dart';
import 'package:citusmail/src/features/reader/state/reader_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'test_app.dart';

/// The mail screen's focused controllers wired together by hand, without
/// `MailController`, so each can be tested directly. Notices and drafts
/// are recorded; [refresh] re-reads the list, the counts and the open
/// message (what the mail screen's refresh does for these tests).
final class Controllers {
  Controllers(this.app) {
    list.show(const InboxLocation());
    compose.onCompose = drafts.add;
  }

  final TestApp app;
  MailStore get store => app.store;

  /// Every notice so far, with its Undo.
  final notices = <(String, VoidCallback?)>[];
  final drafts = <Draft>[];
  var refreshes = 0;

  void notify(String message, {VoidCallback? undo}) =>
      notices.add((message, undo));

  String? get lastNotice => notices.lastOrNull?.$1;

  /// Taps Undo on the last notice.
  void undoLast() => notices.last.$2!();

  void refresh() {
    refreshes++;
    list.refresh();
    counts.refresh();
    reader.refreshOpen();
  }

  late final MessageListModel list = MessageListModel(store);
  late final FollowUpReminders followUps = FollowUpReminders(store);
  late final CountsController counts = CountsController(store, list, followUps);
  late final ComposeStarter compose = ComposeStarter(
    app.services,
    accountInView: () => location.location.value.accountId,
    notify: notify,
  );
  late final ReaderController reader = ReaderController(
    app.services,
    list,
    counts,
    compose,
    refresh: refresh,
  );
  late final SelectionController selection = SelectionController(
    store,
    list,
    openMessage: () => reader.selected,
  );
  late final LocationController location = LocationController(
    store,
    app.services.worker,
    list,
    selection,
    refresh: refresh,
  );
  late final MessageActions actions = MessageActions(
    app.services,
    list,
    location,
    selection,
    reader,
    refresh: refresh,
    notify: notify,
  );

  /// How often the wake timer fired.
  var wakes = 0;
  late final WakeTimer wakeTimer = WakeTimer(
    store,
    followUps,
    onDue: () => wakes++,
  );
  late final SnoozeController snoozes = SnoozeController(
    app.services,
    list,
    location,
    selection,
    reader,
    actions,
    wakeTimer,
    refresh: refresh,
    notify: notify,
  );
  late final FollowUpController followUpController = FollowUpController(
    store,
    followUps,
    wakeTimer,
    refresh: refresh,
    notify: notify,
  );
  late final AwayController away = AwayController(
    app.services.worker,
    list,
    actions,
    snoozes,
    followUpController,
    refresh: refresh,
    notify: notify,
  );

  late final OldCodesController oldCodes = OldCodesController(
    CodeCleaner(store, app.services.actions),
    app.services.worker,
    reader,
    selection,
    refresh: refresh,
    notify: notify,
  );
  late final UnsubscribeController unsubscribe = UnsubscribeController(
    app.services,
    reader,
    actions,
    notify: notify,
  );
  late final BlockingController blocking = BlockingController(
    store,
    app.services.actions,
    actions,
    reader,
    notify: notify,
  );
  late final ScreenerController screener = ScreenerController(
    store,
    app.services.actions,
    actions,
    refresh: refresh,
    notify: notify,
  );

  AccountId get accountId => store.accounts.all().single.id;

  StoredMailbox box(String name) => store.mailboxes
      .forAccount(accountId)
      .firstWhere((b) => b.encodedName == name);

  /// The stored message with [subject], wherever it is now (snoozed
  /// too).
  StoredMessage message(String subject) => store.messages
      .list(MessageQuery(accountIds: [accountId], limit: 500))
      .followedBy(
        store.messages.list(
          MessageQuery(
            accountIds: [accountId],
            section: SmartSection.snoozed,
            limit: 500,
          ),
        ),
      )
      .firstWhere((m) => m.subject == subject);

  void dispose() {
    oldCodes.dispose();
    wakeTimer.dispose();
    snoozes.dispose();
    followUpController.dispose();
    location.dispose();
    selection.dispose();
    reader.dispose();
    compose.dispose();
    counts.dispose();
    list.dispose();
  }
}
