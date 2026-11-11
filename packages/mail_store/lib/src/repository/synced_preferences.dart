// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import '../database/mail_database.dart';
import 'app_data_sync_repository.dart';
import 'screener_repository.dart';
import 'settings_repository.dart';

/// One synced preference as this device has it, ready to travel to the
/// user's other devices.
final class PreferenceEntry {
  const PreferenceEntry(this.key, this.data, this.changedAt);

  /// [AppDataKeys.preference]: the same on every device.
  final String key;
  final Map<String, Object?> data;

  /// When it last changed here; the start of time for a value set before
  /// this version, so that any real change wins over it.
  final DateTime changedAt;
}

/// The app preferences that sync between the user's devices (with sync
/// between devices on), and when each last changed on this device.
///
/// An explicit allowlist ([all]): a setting syncs only when it is listed
/// there on purpose. Every other setting, including any added later,
/// stays on its device. Settings changes go through [SettingsRepository],
/// which tells this class when a listed one changes so it can note the
/// time; the later change wins between devices. A device that never
/// changed a preference has no time for it and takes the other devices'
/// value.
///
/// Never synced, on purpose: new-mail notifications and their previews,
/// "Also for Notifications", instant mail and battery settings, the app
/// lock and PIN, the theme, sidebar folding and other `ui.*` layout,
/// Safe Browsing and VirusTotal (they send data to third parties, so each
/// device agrees to them itself), and bookkeeping (last runs and checks,
/// seen lists, learned weights, when the user was away).
final class SyncedPreferences {
  SyncedPreferences(this._db);

  final MailDatabase _db;

  static const screener = ScreenerRepository.sinceKey;
  static const codeCleanup = 'codes.cleanup';
  static const codeCleanupAge = 'codes.cleanup.age';
  static const codeCleanupAction = 'codes.cleanup.action';
  static const codeCleanupConsent = 'codes.cleanup.consent';
  static const keptSenders = 'cleanup.kept';

  /// The preferences that sync, each for a reason.
  static const all = <String>{
    // The Screener on or off: the user wants mail from new senders to
    // wait, whichever device they read on. Synced as on or off; a device
    // that turns it on counts the senders it has mail from as let in.
    screener,
    // "New since you were away" at the top of the inbox: how the user
    // likes their inbox to look.
    'inbox.newSinceAway',
    // "Read receipts and bookings automatically": what may be downloaded
    // ahead of time from the user's own mail; a choice about their mail.
    'autoRead.on',
    // "Learn from my corrections": the user's wish that their "not a
    // subscription" answers count follows them.
    'learning.on',
    // Bill and trial reminders, and monthly renewals among them: which
    // reminders the user wants. Whether a device shows notifications at
    // all stays on that device.
    'reminders.on',
    'reminders.monthly',
    // Follow-up reminders ("Remind me if no reply") as notifications;
    // the same reasoning as reminders.
    'followUps.notify',
    // Clean-up of old codes: after how long ([codeCleanupAge]), Archive
    // or Trash ([codeCleanupAction]) and the user's agreement to it
    // ([codeCleanupConsent]), as one: the agreement only travels with
    // the rule it agreed to. "Not now" stays on the device that asked.
    codeCleanup,
    // Clean up's Keep list: senders the user keeps. A set: an addition
    // on one device and a removal on another both count.
    keptSenders,
    // Tips switched off: someone who turned tips off doesn't want them
    // again on their next device.
    'tips.off',
  };

  /// The synced preference a setting belongs to, or null when the setting
  /// stays on this device.
  static String? preferenceOf(String settingKey) => switch (settingKey) {
    codeCleanupAge || codeCleanupAction || codeCleanupConsent => codeCleanup,
    _ when all.contains(settingKey) && settingKey != codeCleanup => settingKey,
    _ => null,
  };

  static const _stampPrefix = 'sync.changed:';

  /// When [preference] last changed here, or null if it never did (in
  /// this version).
  DateTime? changedAt(String preference) {
    final ms = int.tryParse(_read('$_stampPrefix$preference') ?? '');
    return ms == null ? null : _time(ms);
  }

  /// Notes that [preference] changed at [at].
  void stamp(String preference, DateTime at) =>
      _write('$_stampPrefix$preference', '${at.millisecondsSinceEpoch}');

  /// Called by [SettingsRepository] when the setting [settingKey] changed
  /// from [old] to [value] (null: removed). [at] and [device]: when
  /// applying another device's change.
  void settingChanged(
    String settingKey,
    String? old,
    String? value, {
    DateTime? at,
    String? device,
  }) {
    final preference = preferenceOf(settingKey);
    if (preference == null || old == value) return;
    final when = (at ?? DateTime.now()).toUtc();
    if (preference == keptSenders) {
      final before = _items(old).toSet(), after = _items(value).toSet();
      final stamps = _itemStamps();
      for (final item in after.difference(before)) {
        stamps[item] = when.millisecondsSinceEpoch;
      }
      for (final item in before.difference(after)) {
        stamps.remove(item);
        AppDataSyncRepository(_db).recordRemoval(
          AppDataKeys.preference(keptSenders, item),
          'preference',
          at: when,
          device: device,
        );
      }
      _write('$_stampPrefix$keptSenders', jsonEncode(stamps));
      return;
    }
    // Only agreeing travels; "Not now" is this device's own answer.
    if (settingKey == codeCleanupConsent && value != 'yes') return;
    stamp(preference, when);
  }

  /// Every synced preference this device has an opinion on.
  List<PreferenceEntry> entries() {
    final out = <PreferenceEntry>[];
    for (final preference in all) {
      if (preference == keptSenders) {
        final stamps = _itemStamps();
        for (final item in _items(_read(keptSenders))) {
          out.add(
            PreferenceEntry(AppDataKeys.preference(keptSenders, item), {
              'key': keptSenders,
              'item': item,
            }, _time(stamps[item] ?? 0)),
          );
        }
        continue;
      }
      final at = changedAt(preference);
      final (data, isSet) = _current(preference);
      // Set before this version (never noted): it still travels, as old
      // as can be, so a device that never touched it takes it. Not the
      // Screener: off and never turned on look the same there.
      if (at == null && (!isSet || preference == screener)) continue;
      out.add(
        PreferenceEntry(AppDataKeys.preference(preference), {
          'key': preference,
          ...data,
        }, at ?? _time(0)),
      );
    }
    return out;
  }

  /// Makes this device follow another device's change of the preference
  /// [key], made at [at] by [device]. Returns whether anything changed
  /// here. Throws [ArgumentError] for a preference this device doesn't
  /// sync (another version's: kept and passed on, never applied), and
  /// [FormatException] for malformed data.
  bool apply(
    String key,
    Map<String, Object?> data, {
    required bool deleted,
    required DateTime at,
    required String device,
  }) => _db.transaction(() {
    final parts = _parts(key);
    final preference = parts.first;
    if (!all.contains(preference)) {
      throw ArgumentError.value(key, 'key', 'not a synced preference here');
    }
    final ms = at.millisecondsSinceEpoch;
    if (parts.length == 2) {
      if (preference != keptSenders) throw FormatException('bad key $key');
      return _applyItem(parts[1], deleted: deleted, at: at, device: device);
    }
    if (parts.length != 1 || deleted) throw FormatException('bad key $key');
    final local =
        changedAt(preference)?.millisecondsSinceEpoch ??
        (preference != screener && _current(preference).$2 ? 0 : null);
    // Changed here since; or both set before this version: each keeps
    // its own until the user changes it somewhere.
    if (local != null && (local > ms || (local == 0 && ms == 0))) {
      return false;
    }
    var changed = false;
    bool put(String settingKey, String? value) {
      if (_read(settingKey) == value) return false;
      final settings = SettingsRepository(_db);
      if (value == null) {
        settings.delete(settingKey, at: at, device: device);
      } else {
        settings.write(settingKey, value, at: at, device: device);
      }
      return true;
    }

    switch (preference) {
      case screener:
        final on = _text(data, 'value') == 'on';
        final repository = ScreenerRepository(_db);
        if (on != repository.enabled) {
          on ? repository.enable() : repository.disable();
          changed = true;
        }
      case codeCleanup:
        changed = put(codeCleanupAge, _text(data, 'age')) | changed;
        changed = put(codeCleanupAction, _text(data, 'action')) | changed;
        final agreed = data['agreed'] == true;
        final consent = _read(codeCleanupConsent);
        if (agreed && consent != 'yes') {
          changed = put(codeCleanupConsent, 'yes') | changed;
        } else if (!agreed && consent == 'yes') {
          // The rule changed where the user hadn't agreed to it: asked
          // again here, never moving mail on an agreement to another rule.
          changed = put(codeCleanupConsent, null) | changed;
        }
      default:
        changed = put(preference, _text(data, 'value'));
    }
    stamp(preference, at); // the change's own time, never newer
    return changed;
  });

  bool _applyItem(
    String item, {
    required bool deleted,
    required DateTime at,
    required String device,
  }) {
    final items = _items(_read(keptSenders));
    final has = items.contains(item);
    final settings = SettingsRepository(_db);
    if (deleted) {
      final kept = _itemStamps()[item];
      if (!has || (kept != null && kept > at.millisecondsSinceEpoch)) {
        return false; // kept again here since
      }
      settings.write(
        keptSenders,
        (items..remove(item)).join(','),
        at: at,
        device: device,
      );
      return true;
    }
    if (has) return false;
    settings.write(keptSenders, [...items, item].join(','), at: at);
    return true;
  }

  /// The value of [preference] here, and whether the user set one.
  (Map<String, Object?>, bool) _current(String preference) {
    switch (preference) {
      case screener:
        final on = ScreenerRepository(_db).enabled;
        return ({'value': on ? 'on' : null}, on);
      case codeCleanup:
        final age = _read(codeCleanupAge), action = _read(codeCleanupAction);
        final agreed = _read(codeCleanupConsent) == 'yes';
        return (
          {'age': age, 'action': action, 'agreed': agreed},
          age != null || action != null || agreed,
        );
      default:
        final value = _read(preference);
        return ({'value': value}, value != null);
    }
  }

  Map<String, int> _itemStamps() {
    try {
      final decoded = jsonDecode(_read('$_stampPrefix$keptSenders') ?? '{}');
      if (decoded is Map) {
        return {
          for (final MapEntry(:key, :value) in decoded.entries)
            if (key is String && value is int) key: value,
        };
      }
    } on FormatException {
      // Damaged: as if never noted.
    }
    return {};
  }

  static List<String> _items(String? value) => [
    ...?value?.split(',').where((s) => s.isNotEmpty),
  ];

  static DateTime _time(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  static List<String> _parts(String key) {
    final colon = key.indexOf(':');
    final Object? parts;
    try {
      parts = colon < 0 ? null : jsonDecode(key.substring(colon + 1));
    } on FormatException {
      throw FormatException('malformed key $key');
    }
    if (parts is! List ||
        parts.isEmpty ||
        parts.length > 2 ||
        parts.any((p) => p is! String)) {
      throw FormatException('malformed key $key');
    }
    return parts.cast<String>();
  }

  static String? _text(Map<String, Object?> data, String name) {
    final value = data[name];
    if (value != null && value is! String) {
      throw FormatException('malformed $name');
    }
    return value as String?;
  }

  String? _read(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  void _write(String key, String value) => _db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );
}
