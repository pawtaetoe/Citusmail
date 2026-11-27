// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mail_store/mail_store.dart';

import '../features/security/state/app_lock.dart';
import 'mail_notices.dart';

/// The newest code still worth copying: what the "Latest code" tile in
/// Android's Quick Settings copies.
@immutable
final class FreshCode {
  const FreshCode({
    required this.messageId,
    required this.sender,
    required this.code,
    required this.at,
  });

  final MessageId messageId;
  final String sender;
  final String code;

  /// When the email came.
  final DateTime at;

  /// When the tile stops offering it.
  DateTime get expires => at.add(LatestCode.freshFor);
}

/// Where the latest code is kept for the tile, which runs with the app
/// closed. On Android: a small value encrypted with a key in the Android
/// Keystore (see LatestCode.kt), kept only while the tile is added.
abstract interface class LatestCodeSlot {
  /// Keeps [code]; false when it was not kept (the tile is not added).
  Future<bool> save(FreshCode code);

  Future<void> clear();
}

/// The Android side of [LatestCodeSlot].
final class AndroidLatestCodeSlot implements LatestCodeSlot {
  const AndroidLatestCodeSlot();

  @override
  Future<bool> save(FreshCode code) async =>
      await LatestCode._channel.invokeMethod<bool>('save', {
        'sender': code.sender,
        'code': code.code,
        'at': code.at.millisecondsSinceEpoch,
        'expires': code.expires.millisecondsSinceEpoch,
      }) ??
      false;

  @override
  Future<void> clear() => LatestCode._channel.invokeMethod<void>('clear');
}

/// Whether Android added the tile when asked.
enum TileRequest { added, alreadyAdded, notAdded, unsupported }

/// Keeps the tile's value up to date: after each check for mail, the
/// newest code in the inboxes that is under [freshFor] old, or nothing.
/// So a code whose email was deleted, or that got too old, is cleared
/// (the tile also drops a value that got too old by itself).
///
/// Nothing is kept while the app lock is on: the tile would show the
/// sender without asking for the PIN.
final class LatestCode {
  LatestCode(this._store, {LatestCodeSlot? slot})
    : _slot = slot ?? (available ? const AndroidLatestCodeSlot() : null);

  final MailStore _store;
  final LatestCodeSlot? _slot;

  /// What was handed to the slot last ('' for nothing), so an unchanged
  /// value is not written again.
  String? _sent;

  /// How long a code is offered: most expire within 10 minutes.
  static const freshFor = Duration(minutes: 10);

  /// Inbox messages looked at, newest first.
  static const _looked = 50;

  static const _channel = MethodChannel('citusmail/latest-code');

  /// The tile exists on Android only.
  static bool get available => !kIsWeb && Platform.isAndroid;

  /// The newest code in the inboxes, if under [freshFor] old.
  static FreshCode? find(MailStore store, {DateTime? now}) {
    if (AppLock.isEnabledIn(store)) return null;
    final at = now ?? DateTime.now();
    StoredMessage? newest;
    for (final m in store.messages.list(
      const MessageQuery.inbox(limit: _looked),
    )) {
      if (m.shownCode == null) continue;
      if (at.difference(m.receivedAt) > freshFor) continue;
      if (newest == null || m.receivedAt.isAfter(newest.receivedAt)) {
        newest = m;
      }
    }
    if (newest == null) return null;
    return FreshCode(
      messageId: newest.id,
      sender: MailNotices.senderName(newest),
      code: newest.shownCode!,
      at: newest.receivedAt,
    );
  }

  /// Hands the current value to the slot, or clears it.
  Future<void> update({DateTime? now}) async {
    final slot = _slot;
    if (slot == null) return;
    try {
      final fresh = find(_store, now: now);
      final key = fresh == null ? '' : '${fresh.messageId.value}:${fresh.code}';
      if (key == _sent) return;
      if (fresh == null) {
        await slot.clear();
        _sent = key;
      } else {
        // Not kept (no tile yet): offered again next time.
        _sent = await slot.save(fresh) ? key : null;
      }
    } on Object catch (e) {
      debugPrint('latest code: ${e.runtimeType}');
    }
  }

  /// Asks Android to add the tile to Quick Settings (Android 13+; before
  /// that, people add it themselves).
  static Future<TileRequest> requestTile() async {
    if (!available) return TileRequest.unsupported;
    try {
      final answer = await _channel.invokeMethod<String>('requestTile');
      return TileRequest.values.firstWhere(
        (r) => r.name == answer,
        orElse: () => TileRequest.unsupported,
      );
    } on Object {
      return TileRequest.unsupported;
    }
  }
}
