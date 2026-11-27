// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_sync/mail_sync.dart';

import '../../../core/state/notice.dart';
import '../../inbox/state/selection_controller.dart';
import '../../reader/state/reader_controller.dart';

/// Old verification codes: whether the Verification section offers to
/// tidy them up, and moving them out of the inbox once agreed.
final class OldCodesController {
  OldCodesController(
    this.codeCleaner,
    this._worker,
    this._reader,
    this._selection, {
    required this._refresh,
    required this._notify,
  });

  /// Moves old verification codes out of the inbox, once agreed.
  final CodeCleaner codeCleaner;
  final SyncWorker _worker;
  final ReaderController _reader;
  final SelectionController _selection;

  /// Re-reads the mail screen after a change.
  final VoidCallback _refresh;
  final ShowNotice _notify;
  bool _disposed = false;

  /// Whether the Verification section asks to tidy up old codes.
  final codesOffer = ValueNotifier<bool>(false);

  /// Asks again (or stops asking) as the settings say.
  void refreshOffer() =>
      codesOffer.value = codeCleaner.shouldAsk(DateTime.now().toUtc());

  /// After a sync: moves old codes out of the inbox (at most once an hour,
  /// once the user agreed), and says so with Undo. The open message and
  /// selected ones stay.
  void tidy([DateTime? now]) {
    if (_disposed) return;
    final done = codeCleaner.run(
      now ?? DateTime.now().toUtc(),
      except: {?_reader.selected?.id, ..._selection.selection.value},
    );
    if (done == null) {
      refreshOffer();
      return;
    }
    for (final receipt in done.receipts) {
      for (final id in receipt.accountIds) {
        _worker.syncAt(id, receipt.undoUntil);
      }
    }
    _refresh();
    _notify(
      done.count == 1
          ? 'Tidied up 1 old code'
          : 'Tidied up ${done.count} old codes',
      undo: () {
        final undone = codeCleaner.undo(done);
        _refresh();
        if (!undone) {
          _notify('Too late to undo: the change reached the server.');
        }
      },
    );
  }

  /// "Turn on" in the Verification section: agrees, and tidies up now.
  void agree() {
    codeCleaner.settings.agree();
    codesOffer.value = false;
    tidy();
  }

  /// "Not now": asked again in a month.
  void decline() {
    codeCleaner.settings.decline(DateTime.now().toUtc());
    codesOffer.value = false;
  }

  void dispose() {
    _disposed = true;
    codesOffer.dispose();
  }
}
