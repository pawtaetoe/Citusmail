// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';

import 'message_list_model.dart';

/// The messages picked in the list for a bulk action.
final class SelectionController {
  SelectionController(this._store, this._list, {required this._openMessage});

  final MailStore _store;
  final MessageListModel _list;

  /// The open message, the target when nothing is selected.
  final StoredMessage? Function() _openMessage;

  /// The ids of the selected messages.
  final selection = ValueNotifier<Set<int>>(const {});

  bool get selecting => selection.value.isNotEmpty;

  /// The message clicked last, where a Shift-click range starts.
  int? _anchor;

  void toggle(StoredMessage m) {
    final next = {...selection.value};
    if (!next.remove(m.id)) next.add(m.id);
    _anchor = m.id;
    selection.value = next;
  }

  /// Selects from the message clicked last to [m] (Shift-click). When that
  /// one is gone from the list or no longer selected, from the selected
  /// message lowest in the list.
  void selectRange(StoredMessage m) {
    final visible = _list.visible;
    final clicked = switch (_anchor) {
      final id? when selection.value.contains(id) => visible.indexWhere(
        (x) => x.id == id,
      ),
      _ => -1,
    };
    final anchor = clicked >= 0
        ? clicked
        : visible.lastIndexWhere((x) => selection.value.contains(x.id));
    final end = visible.indexWhere((x) => x.id == m.id);
    if (anchor < 0 || end < 0) return toggle(m);
    final (from, to) = anchor < end ? (anchor, end) : (end, anchor);
    _anchor = m.id;
    selection.value = {
      ...selection.value,
      for (var i = from; i <= to; i++) visible[i].id,
    };
  }

  void selectAllVisible() =>
      selection.value = {for (final m in _list.visible) m.id};

  void clear() {
    _anchor = null;
    if (selection.value.isNotEmpty) selection.value = const {};
  }

  /// The selected messages, or else the open one.
  List<StoredMessage> get targets {
    if (selection.value.isNotEmpty) {
      return [for (final id in selection.value) ?_store.messages.byId(id)];
    }
    return [?_openMessage()];
  }

  void dispose() => selection.dispose();
}
