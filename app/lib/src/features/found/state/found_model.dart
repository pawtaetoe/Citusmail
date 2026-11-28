// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../core/state/page_model.dart';
import '../../../services/app_services.dart';
import '../../../services/auto_reader.dart';
import '../../inbox/state/corrections.dart';

/// What every "Found in your mail" finder returns besides its own
/// findings: all items the rules found, those the user said are not one
/// ([hidden], by key), those left out because they look like those
/// ([learned], by key), and the emails worth downloading ([toRead]).
typedef Finds<T> = ({
  List<T> all,
  Set<String> hidden,
  Set<String> learned,
  List<MessageId> toRead,
});

/// A found page's data: the finder's own findings ([found]) and the
/// items split into those listed and those left out.
final class FoundPage<T, F> {
  FoundPage(this.found, Finds<T> finds, String Function(T item) keyOf)
    : all = finds.all,
      hidden = finds.hidden,
      learned = finds.learned,
      toRead = finds.toRead,
      listed = [
        for (final item in finds.all)
          if (!finds.hidden.contains(keyOf(item)) &&
              !finds.learned.contains(keyOf(item)))
            item,
      ],
      hiddenOnes = [
        for (final item in finds.all)
          if (finds.hidden.contains(keyOf(item)) ||
              finds.learned.contains(keyOf(item)))
            item,
      ];

  FoundPage._(
    this.found, {
    required this.all,
    required this.hidden,
    required this.learned,
    required this.toRead,
    required this.listed,
    required this.hiddenOnes,
  });

  final F found;

  /// Everything the rules found.
  final List<T> all;
  final Set<String> hidden;
  final Set<String> learned;
  final List<MessageId> toRead;

  /// Those neither [hidden] nor [learned], in the finder's order.
  final List<T> listed;

  /// Those of [hidden] and [learned].
  final List<T> hiddenOnes;

  /// The same split, with [found] changed on the page.
  FoundPage<T, F> withFound(F found) => FoundPage._(
    found,
    all: all,
    hidden: hidden,
    learned: learned,
    toRead: toRead,
    listed: listed,
    hiddenOnes: hiddenOnes,
  );
}

/// The model of a "Found in your mail" page (subscriptions, deliveries,
/// trips, appointments, online accounts): items found in mail on the
/// device, "Not a …" with Undo (learned from, [Corrections]), "List
/// again", and downloading the emails whose preview says too little
/// ([readEmails]), only when the user asks.
///
/// A page says which [kind] of mail its items are, where the ones the
/// user hid are kept ([hiddenKeys]), how to [find] them, how each is
/// keyed ([keyOf]) and what the classifier reads of it ([samplesOf]).
abstract base class FoundModel<T, F> extends PageModel<FoundPage<T, F>> {
  FoundModel(
    this.services, {
    required this.kind,
    required this.hiddenKeys,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppServices services;

  /// What the classifier learns these items as.
  final MailKind kind;

  /// Where the keys of the items the user said are not one are kept.
  final StringListSetting hiddenKeys;

  final DateTime Function() _now;

  /// Now (replaced in tests).
  @protected
  DateTime now() => _now();

  @protected
  MailStore get store => services.store;

  @protected
  String keyOf(T item);

  /// What the classifier reads of [item]'s emails.
  @protected
  List<MailSample> samplesOf(T item);

  /// Reads the page's findings at [now], [skip] left out of what to read.
  @protected
  Future<F> find(DateTime now, Set<MessageId> skip);

  /// The parts of [found] every found page has.
  @protected
  Finds<T> findsOf(F found);

  @override
  Future<FoundPage<T, F>> fetch() async {
    final found = await find(now(), _skip);
    return FoundPage(found, findsOf(found), keyOf);
  }

  /// Emails given up on: not offered while they are read automatically.
  Set<MessageId> get _skip =>
      services.settings.autoRead ? ReadFailures(store).givenUp : const {};

  late final _corrections = Corrections(store);

  /// The finder's own findings, once loaded.
  @protected
  F? get found => data?.found;

  /// Items the user said are not one (by key).
  Set<String> get hidden => data?.hidden ?? const {};

  /// Items left out because they look like ones the user said are not
  /// one ("Learn from my corrections"; by key).
  Set<String> get learned => data?.learned ?? const {};

  /// The items listed: neither [hidden] nor [learned].
  @protected
  List<T> get listed => data?.listed ?? const [];

  /// Those of [hidden] and [learned].
  List<T> get hiddenOnes => data?.hiddenOnes ?? const [];

  /// Emails not on the device yet whose whole text may say more.
  List<MessageId> get toRead => data?.toRead ?? const [];

  /// While reading emails: how many are done, of how many.
  ({int done, int total})? reading;
  bool _stop = false;

  /// Downloads the emails in [toRead] from the user's own mail server
  /// (they stay unread), then looks again. Stops early on [stopReading].
  Future<void> readEmails() async {
    if (reading != null || toRead.isEmpty) return;
    final ids = toRead;
    _stop = false;
    var done = 0;
    reading = (done: 0, total: ids.length);
    notify();
    for (final id in ids) {
      if (_stop) break;
      try {
        await services.worker.loadBody(id);
      } on Object {
        // Gone, too large or offline: read from its preview only.
      }
      reading = (done: ++done, total: ids.length);
      notify();
    }
    reading = null;
    await load();
  }

  void stopReading() => _stop = true;

  /// "Not a …": hidden from the list (undoable), and learned from.
  void hide(String key) {
    if (_found(key) case final item?) {
      _corrections.rejected(kind, samplesOf(item));
    }
    writeKeys(hiddenKeys, {...hidden, key});
  }

  /// Undo, or "List again": listed again (and never left out by
  /// learning again).
  void unhide(String key) {
    final item = _found(key);
    final samples = item == null ? const <MailSample>[] : samplesOf(item);
    if (hidden.contains(key)) {
      if (item != null) _corrections.rejected(kind, samples, undo: true);
      writeKeys(hiddenKeys, unhidden(hidden, key));
    } else if (learned.contains(key)) {
      _corrections.kept(kind, key, samples);
      unawaited(load());
    }
  }

  /// [hidden] once the item keyed [key] is listed again.
  @protected
  Set<String> unhidden(Set<String> hidden, String key) =>
      {...hidden}..remove(key);

  /// [item]'s page was opened: a weak sign that it is one.
  void opened(T item) =>
      _corrections.opened(kind, keyOf(item), samplesOf(item));

  T? _found(String key) =>
      (data?.all ?? const []).where((item) => keyOf(item) == key).firstOrNull;

  /// Keeps [keys] in [setting], then looks again.
  @protected
  void writeKeys(StringListSetting setting, Set<String> keys) {
    setting.write(store.settings, keys.toList());
    unawaited(load());
  }

  StoredMessage? message(MessageId id) => store.messages.byId(id);
}
