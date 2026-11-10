// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';

import '../database/mail_database.dart';
import 'app_data_sync_repository.dart';

/// Text put at the end of a message ("Best regards, Tommy"): what other
/// apps call a signature.
final class SignOff {
  const SignOff({
    required this.id,
    required this.name,
    required this.text,
    this.separator = false,
    this.position = 0,
    required this.changedAt,
  });

  /// Text written for one message only, not kept in the list.
  SignOff.oneOff({required String text, bool separator = false})
    : this(
        id: '',
        name: 'This email only',
        text: text,
        separator: separator,
        changedAt: DateTime.utc(1970),
      );

  /// The same on every device (random); empty for a one-off.
  final String id;

  /// A short name to choose it by ("Work", "Casual").
  final String name;

  /// Plain text, possibly several lines.
  final String text;

  /// Starts with the standard signature separator line (`-- `), which
  /// many mail apps recognise (and can hide or leave out of replies).
  final bool separator;

  /// Where it is in the list (lowest first).
  final int position;
  final DateTime changedAt;

  /// Kept in the list (not written for one message only).
  bool get isSaved => id.isNotEmpty;

  /// The text as it goes into the message.
  String get block {
    final body = text.trimRight();
    return separator ? '-- \n$body' : body;
  }

  SignOff copyWith({
    String? name,
    String? text,
    bool? separator,
    int? position,
    DateTime? changedAt,
  }) => SignOff(
    id: id,
    name: name ?? this.name,
    text: text ?? this.text,
    separator: separator ?? this.separator,
    position: position ?? this.position,
    changedAt: changedAt ?? this.changedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'text': text,
    if (separator) 'sep': true,
    'pos': position,
    'at': changedAt.millisecondsSinceEpoch,
  };

  /// Null for anything malformed.
  static SignOff? fromJson(Object? json) {
    if (json case {
      'id': final String id,
      'name': final String name,
      'text': final String text,
    }) {
      final pos = json['pos'], at = json['at'];
      return SignOff(
        id: id,
        name: name,
        text: text,
        separator: json['sep'] == true,
        position: pos is int ? pos : 0,
        changedAt: DateTime.fromMillisecondsSinceEpoch(
          at is int ? at : 0,
          isUtc: true,
        ),
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SignOff &&
      other.id == id &&
      other.name == name &&
      other.text == text &&
      other.separator == separator;

  @override
  int get hashCode => Object.hash(id, name, text, separator);

  @override
  String toString() => 'SignOff($name)';
}

/// Which sign-off an account starts new messages, and replies and
/// forwards, with.
final class SignOffDefaults {
  const SignOffDefaults({
    this.newMail,
    this.repliesSameAsNew = true,
    this.replies,
    required this.changedAt,
  });

  static final none = SignOffDefaults(changedAt: DateTime.utc(1970));

  /// The sign-off's id, or null for none.
  final String? newMail;

  /// Replies and forwards use [newMail] too.
  final bool repliesSameAsNew;

  /// For replies and forwards when not [repliesSameAsNew]; null for none.
  final String? replies;
  final DateTime changedAt;

  /// The id for a reply or forward ([reply]) or a new message.
  String? idFor({required bool reply}) =>
      reply && !repliesSameAsNew ? replies : newMail;

  Map<String, Object?> toJson() => {
    'new': newMail,
    'same': repliesSameAsNew,
    'replies': replies,
    'at': changedAt.millisecondsSinceEpoch,
  };

  static SignOffDefaults fromJson(Object? json) {
    if (json is! Map) return none;
    final newMail = json['new'], replies = json['replies'], at = json['at'];
    return SignOffDefaults(
      newMail: newMail is String ? newMail : null,
      repliesSameAsNew: json['same'] != false,
      replies: replies is String ? replies : null,
      changedAt: DateTime.fromMillisecondsSinceEpoch(
        at is int ? at : 0,
        isUtc: true,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SignOffDefaults &&
      other.newMail == newMail &&
      other.repliesSameAsNew == repliesSameAsNew &&
      other.replies == replies;

  @override
  int get hashCode => Object.hash(newMail, repliesSameAsNew, replies);
}

/// The user's sign-offs and each account's default, kept in the settings
/// table (accounts are named by address, the same on every device).
final class SignOffRepository {
  SignOffRepository(this._db, {Random? random})
    : _random = random ?? Random.secure();

  final MailDatabase _db;
  final Random _random;

  static const _key = 'signOffs';

  /// Kinds of sync records (see `AppDataKeys`).
  static const kind = 'signOff';
  static const defaultsKind = 'signOffDefaults';

  /// All sign-offs, in the user's order.
  List<SignOff> all() => _read().items
    ..sort(
      (a, b) => a.position != b.position
          ? a.position.compareTo(b.position)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

  SignOff? byId(String id) =>
      _read().items.where((s) => s.id == id).firstOrNull;

  /// Adds a sign-off at the end of the list.
  SignOff add({
    required String name,
    required String text,
    bool separator = false,
    DateTime? now,
  }) => _db.transaction(() {
    final data = _read();
    final position = data.items.fold(-1, (m, s) => max(m, s.position)) + 1;
    final signOff = SignOff(
      id: _newId(),
      name: name.trim(),
      text: text.trimRight(),
      separator: separator,
      position: position,
      changedAt: (now ?? DateTime.now()).toUtc(),
    );
    _write(data.items..add(signOff), data.defaults);
    return signOff;
  });

  /// Saves changes to [signOff] (name, text, separator).
  SignOff update(SignOff signOff, {DateTime? now}) => _db.transaction(() {
    final changed = signOff.copyWith(
      name: signOff.name.trim(),
      text: signOff.text.trimRight(),
      changedAt: (now ?? DateTime.now()).toUtc(),
    );
    restore(changed);
    return changed;
  });

  /// Puts [signOff] in as it is (from another device), replacing any with
  /// its id.
  void restore(SignOff signOff) => _db.transaction(() {
    final data = _read();
    _write([
      for (final s in data.items)
        if (s.id != signOff.id) s,
      signOff,
    ], data.defaults);
  });

  /// Removes a sign-off. Defaults that named it now mean none.
  void remove(String id, {DateTime? at, String? device}) => _db.transaction(() {
    final data = _read();
    if (!data.items.any((s) => s.id == id)) return;
    _write([
      for (final s in data.items)
        if (s.id != id) s,
    ], data.defaults);
    AppDataSyncRepository(_db)
        .recordRemoval(AppDataKeys.signOff(id), kind, at: at, device: device);
  });

  /// Puts the sign-offs in the order of [ids] (others keep theirs, after).
  void reorder(List<String> ids, {DateTime? now}) => _db.transaction(() {
    final data = _read();
    final at = (now ?? DateTime.now()).toUtc();
    final ordered = [
      for (final id in ids) ?data.items.where((s) => s.id == id).firstOrNull,
      for (final s in data.items)
        if (!ids.contains(s.id)) s,
    ];
    _write([
      for (final (i, s) in ordered.indexed)
        s.position == i ? s : s.copyWith(position: i, changedAt: at),
    ], data.defaults);
  });

  /// The defaults of the account with address [email].
  SignOffDefaults defaultsFor(String email) =>
      _read().defaults[email.toLowerCase()] ?? SignOffDefaults.none;

  /// Every account's defaults, by lowercase address.
  Map<String, SignOffDefaults> allDefaults() => _read().defaults;

  void setDefaults(String email, SignOffDefaults defaults) =>
      _db.transaction(() {
        final data = _read();
        _write(data.items, {...data.defaults, email.toLowerCase(): defaults});
      });

  /// The sign-off a message from [email] starts with: for a reply or
  /// forward when [reply]. Null for none.
  SignOff? defaultFor(String email, {required bool reply}) {
    final id = defaultsFor(email).idFor(reply: reply);
    return id == null ? null : byId(id);
  }

  String _newId() => [
    for (var i = 0; i < 8; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  ({List<SignOff> items, Map<String, SignOffDefaults> defaults}) _read() {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [_key]);
    Object? json;
    try {
      json = rows.isEmpty ? null : jsonDecode(rows.first.columnAt(0) as String);
    } on FormatException {
      json = null; // damaged: start again rather than block writing
    }
    final items = json is Map && json['items'] is List
        ? [for (final s in json['items'] as List) ?SignOff.fromJson(s)]
        : <SignOff>[];
    final defaults = json is Map && json['defaults'] is Map
        ? {
            for (final MapEntry(:key, :value)
                in (json['defaults'] as Map).entries)
              if (key is String) key: SignOffDefaults.fromJson(value),
          }
        : <String, SignOffDefaults>{};
    return (items: items, defaults: defaults);
  }

  void _write(List<SignOff> items, Map<String, SignOffDefaults> defaults) =>
      _db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?) '
        'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
        [
          _key,
          jsonEncode({
            'v': 1,
            'items': [for (final s in items) s.toJson()],
            'defaults': {
              for (final MapEntry(:key, :value) in defaults.entries)
                key: value.toJson(),
            },
          }),
        ],
      );
}
