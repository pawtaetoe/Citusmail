// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../services/app_settings.dart';

/// What the app learned from the user's corrections ("Not a
/// subscription", "Not a delivery", "Not a booking", "Not an account",
/// "Not an appointment", and "List again"), kept in the settings store on the device. Found
/// items that look like ones the user rejected are left out
/// ([vetoed]); nothing is ever added.
///
/// Off ("Learn from my corrections" in Settings, Advanced), nothing is
/// learned or left out: the pages show exactly what the rules find.
final class Corrections {
  Corrections(this._store);

  final MailStore _store;

  static const _modelKey = 'learning.model';

  /// Items the user listed again after learning hid them ("kind/key").
  static const _keptKey = 'learning.kept';

  /// Items opened, which counted once each ("kind/key", the newest last).
  static const _openedKey = 'learning.opened';
  static const _openedMax = 300;

  bool get on => AppSettings(_store).learnFromCorrections;

  MailTypeClassifier _load() =>
      MailTypeClassifier.fromText(_store.settings.read(_modelKey));

  void _save(MailTypeClassifier classifier) {
    if (classifier.isEmpty) {
      _store.settings.delete(_modelKey);
    } else {
      _store.settings.write(_modelKey, classifier.toText());
    }
  }

  /// The user said the item made of [emails] is not a [kind] (or, with
  /// [undo], took that back).
  void rejected(
    MailKind kind,
    Iterable<MailSample> emails, {
    bool undo = false,
  }) {
    if (!on) return;
    final classifier = _load();
    for (final email in emails) {
      classifier.reject(kind, email, undo: undo);
    }
    _save(classifier);
  }

  /// The user listed again an item learning had hid ([key], made of
  /// [emails]): it is never left out again, and counts for [kind].
  void kept(MailKind kind, String key, Iterable<MailSample> emails) {
    _write(_keptKey, {..._read(_keptKey), '${kind.code}/$key'});
    if (!on) return;
    final classifier = _load();
    for (final email in emails) {
      classifier.confirm(kind, email);
    }
    _save(classifier);
  }

  /// The user opened an item the rules found: a weak sign that it is one,
  /// counted once per item, and only once something was learned against
  /// [kind] (else nothing changes).
  void opened(MailKind kind, String key, Iterable<MailSample> emails) {
    if (!on) return;
    final classifier = _load();
    if (!classifier.hasCorrections(kind)) return;
    final opened = _readList(_openedKey);
    final id = '${kind.code}/$key';
    if (opened.contains(id)) return;
    for (final email in emails.take(6)) {
      classifier.confirm(kind, email, weight: MailTypeClassifier.openedWeight);
    }
    _save(classifier);
    final list = [...opened, id];
    _store.settings.write(
      _openedKey,
      list
          .skip(list.length > _openedMax ? list.length - _openedMax : 0)
          .join('\n'),
    );
  }

  /// "Forget what it learned": everything learned is gone, and every
  /// page shows what the rules find again.
  void forget() {
    _store.settings.delete(_modelKey);
    _store.settings.delete(_keptKey);
    _store.settings.delete(_openedKey);
  }

  /// Whether anything was learned.
  bool get learnedAnything =>
      _store.settings.read(_modelKey) != null ||
      _store.settings.read(_keptKey) != null;

  /// The keys of [items] (each key and its emails) to leave out as not a
  /// [kind]: most of their emails look like ones the user rejected.
  /// Worked out off the UI thread; none when learning is off or nothing
  /// was learned against [kind].
  Future<Set<String>> vetoed(
    MailKind kind,
    Map<String, List<MailSample>> items,
  ) async {
    if (!on || items.isEmpty) return const {};
    final text = _store.settings.read(_modelKey);
    if (!MailTypeClassifier.fromText(text).hasCorrections(kind)) {
      return const {};
    }
    final kept = _read(_keptKey);
    final open = {
      for (final MapEntry(:key, :value) in items.entries)
        if (!kept.contains('${kind.code}/$key')) key: value,
    };
    if (open.isEmpty) return const {};
    return compute(_vetoed, (text, kind, open));
  }

  Set<String> _read(String key) => {..._readList(key)};

  List<String> _readList(String key) => [
    ...?_store.settings.read(key)?.split('\n').where((s) => s.isNotEmpty),
  ];

  void _write(String key, Set<String> values) =>
      _store.settings.write(key, values.join('\n'));
}

Set<String> _vetoed((String?, MailKind, Map<String, List<MailSample>>) args) {
  final (text, kind, items) = args;
  final classifier = MailTypeClassifier.fromText(text);
  return {
    for (final MapEntry(:key, :value) in items.entries)
      if (classifier.rejectsItem(kind, value)) key,
  };
}

/// What the classifier reads of a stored message whose text is [text]
/// (its preview, or the downloaded body) and whose sender's registrable
/// domain is [domain].
MailSample mailSample(
  StoredMessage? message, {
  required String domain,
  required String subject,
  required String text,
  String? senderName,
}) => MailSample(
  address: message?.from?.address,
  domain: domain,
  senderName: senderName,
  subject: subject,
  text: text,
  bulk:
      message != null &&
      (message.listId != null ||
          message.category == MessageCategory.newsletters),
);
