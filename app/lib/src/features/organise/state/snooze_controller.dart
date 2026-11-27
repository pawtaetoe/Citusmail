// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../core/state/notice.dart';
import '../../../services/app_services.dart';
import '../../inbox/state/location_controller.dart';
import '../../inbox/state/mail_location.dart';
import '../../inbox/state/message_actions.dart';
import '../../inbox/state/message_list_model.dart';
import '../../inbox/state/selection_controller.dart';
import '../../reader/state/reader_controller.dart';
import 'wake_timer.dart';

/// Snoozing mail (it leaves the inbox until its time, on this device
/// only), bringing it back early, and waking what is due.
final class SnoozeController {
  SnoozeController(
    this._services,
    this._list,
    this._location,
    this._selection,
    this._reader,
    this._actions,
    this._wakeTimer, {
    required this._refresh,
    required this._notify,
  });

  final AppServices _services;
  final MessageListModel _list;
  final LocationController _location;
  final SelectionController _selection;
  final ReaderController _reader;
  final MessageActions _actions;
  final WakeTimer _wakeTimer;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;
  bool _disposed = false;

  MailStore get _store => _services.store;

  /// Announces snoozed mail that came back (set by the screen that can
  /// post notifications).
  void Function(BackFromSnooze back)? onBackFromSnooze;

  /// Whether [m] can be snoozed: inbox mail with a Message-ID (what keeps
  /// it the same message on every device).
  bool canSnooze(StoredMessage m) =>
      m.messageId != null &&
      (_store.mailboxes.byId(m.mailboxId)?.isInbox ?? false);

  /// When [m] comes back, while it is snoozed.
  DateTime? snoozedUntil(StoredMessage m) {
    final id = m.messageId;
    if (id == null || m.section != SmartSection.snoozed) return null;
    return _list.snoozedUntil[id] ?? _store.snoozes.find(id)?.until;
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
      _notify('This email can\'t be snoozed.');
      return;
    }
    final ids = {for (final m in targets) m.messageId!};
    final previous = {for (final id in ids) id: _store.snoozes.find(id)};
    _store.transaction(() {
      for (final id in ids) {
        _store.snoozes.snooze(id, until);
      }
    });
    final open = _reader.selected;
    final visible = _list.visible;
    _selection.clear();
    if (_location.location.value is SnoozedLocation) {
      _refresh();
    } else {
      _actions.leaveList(open, visible, {for (final m in targets) m.id});
    }
    _notify(
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
        _refresh();
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
    final open = _reader.selected;
    final visible = _list.visible;
    _selection.clear();
    if (_location.location.value is SnoozedLocation) {
      _actions.leaveList(open, visible, {for (final m in messages) m.id});
    } else {
      _refresh();
    }
    _notify(
      ended.length == 1 ? 'Unsnoozed' : 'Unsnoozed ${ended.length}',
      undo: () {
        _store.transaction(() {
          for (final s in ended) {
            _store.snoozes.snooze(s.messageId, s.until);
          }
        });
        _refresh();
      },
    );
  }

  /// Brings back snoozed mail whose time came (or that got a reply),
  /// marked unread, and announces it ([onBackFromSnooze]). Run after each
  /// sync, when the app comes to the foreground, and at the next due time.
  void wake([DateTime? now]) {
    if (_disposed) return;
    try {
      final back = SnoozeWaker(_store, _services.actions).wake(now: now);
      if (!back.isEmpty) {
        for (final id in back.accountIds) {
          _services.worker.requestSync(id);
        }
        _refresh();
        onBackFromSnooze?.call(back);
      }
    } on Object catch (e) {
      debugPrint('snooze: ${e.runtimeType}');
    }
    _wakeTimer.schedule();
  }

  void dispose() => _disposed = true;
}
