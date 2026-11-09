// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../mail/accounts_model.dart';
import '../mail/appointments_model.dart';
import '../mail/deliveries_model.dart';
import '../mail/message_reads.dart';
import '../mail/subscriptions_model.dart';
import '../mail/trips_model.dart';
import 'app_settings.dart';

/// Downloads one message's body into the store (BODY.PEEK: it stays
/// unread), as `SyncWorker.loadBody` and `SyncEngine.loadBody` do.
typedef BodyLoader = Future<void> Function(int messageId);

/// "Read receipts and bookings automatically" (on by default): the
/// receipts, bills, shipping, booking, appointment and account emails
/// that Subscriptions, Deliveries, Trips, Appointments and Online accounts
/// would read are downloaded ahead of time, quietly, so the pages are
/// filled in when opened.
///
/// It is the same as opening those emails on the device: they come from
/// the user's own mail server with BODY.PEEK, so they stay unread; no read
/// receipt is sent and no remote image loads (the pages read only the
/// text and the booking data in it). Nothing else is contacted.
///
/// A run happens a little after the app starts and after a sync brings
/// new mail (debounced), one message at a time, at most [cap] messages;
/// the next run carries on with the rest. A message that cannot be read
/// is skipped (offline: the whole account, until the next run) and, after
/// [ReadFailures.giveUpAfter] failures, no longer tried.
///
/// Each page keeps what it read of each message ([MessageReads]), so a
/// run parses only mail that is new or whose body arrived since the last
/// one; with nothing new, no body is loaded and no worker is started.
final class AutoReader extends ChangeNotifier {
  AutoReader(
    this._store,
    this._load, {
    this.cap = appCap,
    this.delay = const Duration(seconds: 10),
    this.firstDelay = const Duration(seconds: 20),
    this.minGap = const Duration(minutes: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final MailStore _store;
  final BodyLoader _load;
  final DateTime Function() _now;

  /// Messages downloaded at most per run, in the app and in the Android
  /// background check.
  static const appCap = 50;
  static const backgroundCap = 15;

  /// At most this many messages per run.
  final int cap;

  /// How long a request waits for more (several syncs end close together).
  final Duration delay;

  /// The first run after [start].
  final Duration firstDelay;

  /// At least this long between the end of one run and the next.
  final Duration minGap;

  Timer? _timer;
  StreamSubscription<SyncEvent>? _events;
  bool _running = false;
  bool _again = false;
  bool _started = false;
  bool _stopped = false;
  DateTime? _lastEnd;
  int _downloaded = 0;

  /// Whether a run is waiting or going on: the pages say "Reading …".
  bool get active => _timer != null || _running;

  /// Messages downloaded since the app started; the pages look again when
  /// it changes.
  int get downloaded => _downloaded;

  bool get _on => AppSettings(_store).autoRead;

  /// Reads a little after now, and after each sync that brings new mail.
  void start(Stream<SyncEvent> events) {
    _started = true;
    _stopped = false;
    _events ??= events.listen((event) {
      if (event is AccountSynced &&
          event.report.mailboxes.values.any(
            (r) => r.added + r.backfilled > 0,
          )) {
        request();
      }
    });
    request(after: firstDelay);
  }

  /// A run soon (a page was opened with emails left to read, new mail
  /// came, or the setting was turned on). Nothing when it is off, or
  /// before [start].
  void request({Duration? after}) {
    if (!_started || _stopped || !_on) return;
    if (_running) {
      _again = true;
      return;
    }
    var wait = after ?? delay;
    if (_lastEnd case final end?) {
      final gap = end.add(minGap).difference(_now());
      if (gap > wait) wait = gap;
    }
    final wasActive = active;
    _timer?.cancel();
    _timer = Timer(wait, () {
      _timer = null;
      unawaited(run());
    });
    if (!wasActive) notifyListeners();
  }

  /// One run now; returns how many messages were downloaded.
  Future<int> run() async {
    if (_running || _stopped || !_on) return 0;
    _timer?.cancel();
    _timer = null;
    _running = true;
    _again = false;
    notifyListeners();
    var count = 0;
    try {
      final ids = await wanted(_store, _now(), cap: cap);
      final unreachable = <int>{};
      final failures = ReadFailures(_store);
      for (final id in ids) {
        if (_stopped || !_on) break;
        final message = _store.messages.byId(id);
        if (message == null || _store.messages.body(id) != null) continue;
        if (unreachable.contains(message.accountId)) continue;
        try {
          await _load(id);
        } on Object catch (e) {
          if (_stopped) break;
          // Offline or signed out: the account waits for the next run.
          // Anything else counts against this message.
          if (_accountProblem(e)) {
            unreachable.add(message.accountId);
          } else {
            failures.failed(id);
          }
          continue;
        }
        if (_stopped) break;
        count++;
        _downloaded++;
        // The pages fill in as it goes.
        if (count % 10 == 0) notifyListeners();
      }
    } on Object catch (e) {
      debugPrint('auto read: ${e.runtimeType}');
    } finally {
      _running = false;
      _lastEnd = _now();
      if (!_stopped) {
        notifyListeners();
        if (_again) request();
      }
    }
    return count;
  }

  /// Stops reading (the app is closing); a run going on ends after the
  /// message it is on.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_events?.cancel());
    _events = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  /// One run in the Android background check, with its own connection.
  static Future<int> readOnce(
    MailStore store,
    BodyLoader load, {
    int cap = backgroundCap,
  }) => AutoReader(store, load, cap: cap).run();

  /// What the pages would read, taken from each in turn (so every page
  /// gets some when there are many), at most [cap], leaving out those
  /// given up on.
  static Future<List<int>> wanted(
    MailStore store,
    DateTime now, {
    required int cap,
  }) async {
    final skip = ReadFailures(store).givenUp;
    final lists = [
      (await findSubscriptions(
        store,
        now,
        monthlyRenewals: AppSettings(store).monthlyRenewals,
        skip: skip,
      )).toRead,
      (await findTrips(store, now, skip: skip)).toRead,
      (await findDeliveries(store, now, skip: skip)).toRead,
      (await findAppointments(store, now, skip: skip)).toRead,
      (await findOnlineAccounts(store, now, skip: skip)).toRead,
    ];
    final ids = <int>{};
    for (var i = 0; ids.length < cap && lists.any((l) => i < l.length); i++) {
      for (final list in lists) {
        if (i < list.length && ids.length < cap) ids.add(list[i]);
      }
    }
    return ids.toList();
  }

  /// Whether [error] concerns the whole account (offline, the sign-in or
  /// the connection's security) rather than the message.
  static bool _accountProblem(Object error) {
    if (error is BodyUnavailableException) return false;
    final kind = switch (error) {
      SyncWorkerException(:final failure) => failure.kind,
      _ => SyncFailure.from(error).kind,
    };
    return kind != SyncFailureKind.server;
  }
}

/// Messages that could not be downloaded, with how many times, in the
/// settings store ("id:times", the latest last; at most [keep]).
final class ReadFailures {
  ReadFailures(this._store);

  final MailStore _store;

  static const key = 'autoRead.failed';

  /// Failed this often: no longer tried.
  static const giveUpAfter = 3;

  /// Failures remembered at most (the oldest are forgotten, and so tried
  /// again).
  static const keep = 200;

  Map<int, int> _read() {
    final counts = <int, int>{};
    for (final entry in (_store.settings.read(key) ?? '').split(',')) {
      final [id, times] = switch (entry.split(':')) {
        [final a, final b] => [int.tryParse(a), int.tryParse(b)],
        _ => [null, null],
      };
      if (id != null && times != null) counts[id] = times;
    }
    return counts;
  }

  /// Messages no longer tried.
  Set<int> get givenUp => {
    for (final MapEntry(:key, :value) in _read().entries)
      if (value >= giveUpAfter) key,
  };

  /// How many times [messageId] failed.
  int times(int messageId) => _read()[messageId] ?? 0;

  void failed(int messageId) {
    final counts = _read();
    final times = (counts.remove(messageId) ?? 0) + 1;
    counts[messageId] = times;
    final entries = counts.entries.toList();
    final kept = entries.skip(
      entries.length > keep ? entries.length - keep : 0,
    );
    _store.settings.write(
      key,
      [for (final MapEntry(:key, :value) in kept) '$key:$value'].join(','),
    );
  }
}
