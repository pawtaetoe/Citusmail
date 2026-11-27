// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../../../services/app_settings.dart';

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

  /// What was learned, as [MailLearning.toText]: the classifier's
  /// corrections first (as [MailTypeClassifier.toText], which older
  /// versions read), then the mail model's adjustments.
  static const modelSetting = StringSetting('learning.model');

  /// Items the user listed again after learning hid them ("kind/key").
  static const keptSetting = StringListSetting(
    'learning.kept',
    separator: '\n',
  );

  /// Items opened, which counted once each ("kind/key", the newest last).
  static const openedSetting = StringListSetting(
    'learning.opened',
    separator: '\n',
  );
  static const _openedMax = 300;

  bool get on => AppSettings(_store).learnFromCorrections;

  MailLearning _load() =>
      MailLearning.fromText(modelSetting.readOrNull(_store.settings));

  void _save(MailLearning learning) {
    if (learning.isEmpty) {
      modelSetting.clear(_store.settings);
    } else {
      modelSetting.write(_store.settings, learning.toText());
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
    final learning = _load();
    for (final email in emails) {
      learning.reject(kind, email, undo: undo);
    }
    _save(learning);
  }

  /// The user listed again an item learning had hid ([key], made of
  /// [emails]): it is never left out again, and counts for [kind].
  void kept(MailKind kind, String key, Iterable<MailSample> emails) {
    _write(keptSetting, {..._read(keptSetting), '${kind.code}/$key'});
    if (!on) return;
    final learning = _load();
    for (final email in emails) {
      learning.confirm(kind, email);
    }
    _save(learning);
  }

  /// The user opened an item the rules found: a weak sign that it is one,
  /// counted once per item, and only once something was learned against
  /// [kind] (else nothing changes).
  void opened(MailKind kind, String key, Iterable<MailSample> emails) {
    if (!on) return;
    final learning = _load();
    if (!learning.hasCorrections(kind)) return;
    final opened = _readList(openedSetting);
    final id = '${kind.code}/$key';
    if (opened.contains(id)) return;
    for (final email in emails.take(6)) {
      learning.confirm(kind, email, weight: MailTypeClassifier.openedWeight);
    }
    _save(learning);
    final list = [...opened, id];
    openedSetting.write(
      _store.settings,
      list
          .skip(list.length > _openedMax ? list.length - _openedMax : 0)
          .toList(),
    );
  }

  /// "Forget what it learned": everything learned is gone, and every
  /// page shows what the rules find again.
  void forget() {
    modelSetting.clear(_store.settings);
    keptSetting.clear(_store.settings);
    openedSetting.clear(_store.settings);
    SenderSortChoices(_store).clear();
  }

  /// Whether anything was learned.
  bool get learnedAnything =>
      modelSetting.isSetIn(_store.settings) ||
      keptSetting.isSetIn(_store.settings) ||
      SenderSortChoices.setting.isSetIn(_store.settings);

  /// The keys of [items] (each key and its emails) to leave out as not a
  /// [kind]: most of their emails look like ones the user rejected.
  /// Worked out off the UI thread; none when learning is off or nothing
  /// was learned against [kind].
  Future<Set<String>> vetoed(
    MailKind kind,
    Map<String, List<MailSample>> items,
  ) async {
    if (!on || items.isEmpty) return const {};
    final text = modelSetting.readOrNull(_store.settings);
    if (!MailTypeClassifier.fromText(text).hasCorrections(kind)) {
      return const {};
    }
    final kept = _read(keptSetting);
    final open = {
      for (final MapEntry(:key, :value) in items.entries)
        if (!kept.contains('${kind.code}/$key')) key: value,
    };
    if (open.isEmpty) return const {};
    return compute(_vetoed, (text, kind, open));
  }

  Set<String> _read(StringListSetting setting) => {..._readList(setting)};

  List<String> _readList(StringListSetting setting) =>
      setting.read(_store.settings);

  void _write(StringListSetting setting, Set<String> values) =>
      setting.write(_store.settings, values.toList());
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
