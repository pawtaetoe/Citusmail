// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The "Latest code" tile's value: the newest fresh code in the inboxes,
// kept up to date after each check for mail.

import 'package:citusmail/src/services/latest_code.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import 'support/test_app.dart';

/// Records what the tile would be given.
final class _FakeSlot implements LatestCodeSlot {
  final saved = <FreshCode>[];
  var clears = 0;

  /// Whether the tile is added (otherwise nothing is kept).
  var keeps = true;

  @override
  Future<bool> save(FreshCode code) async {
    if (keeps) saved.add(code);
    return keeps;
  }

  @override
  Future<void> clear() async => clears++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestApp app;
  late StoredMailbox inbox;
  late _FakeSlot slot;
  late LatestCode latest;
  setUp(() async {
    app = await TestApp.create();
    inbox = app.store.mailboxes.inbox(app.store.accounts.all().single.id)!;
    slot = _FakeSlot();
    latest = LatestCode(app.store, slot: slot);
  });
  tearDown(() => app.dispose());

  final now = DateTime.utc(2026, 11, 26, 14, 30);

  /// A verification email that came [ago], with [code] as the code reader
  /// found it ('' for none, null for not looked at yet).
  StoredMessage arrive(
    int uid,
    Duration ago, {
    String? code,
    String name = 'Northwind Bank',
  }) {
    app.store.messages.upsertSummaries(inbox.id, [
      MessageSummary(
        uid: uid,
        receivedAt: now.subtract(ago),
        subject: 'Your one-time passcode',
        from: MailAddress(
          displayName: name,
          localPart: 'alerts',
          domain: 'northwindbank.example',
        ),
        category: MessageCategory.codes,
      ),
    ]);
    final m = app.store.messages.byUid(inbox.id, uid)!;
    if (code != null) app.store.messages.setCode(m.id, code);
    return app.store.messages.byId(m.id)!;
  }

  test('a new code is handed to the tile: sender, code and time', () async {
    final bank = arrive(200, const Duration(minutes: 2), code: '482913');
    await latest.update(now: now);
    final saved = slot.saved.single;
    expect(saved.messageId, bank.id);
    expect(saved.sender, 'Northwind Bank');
    expect(saved.code, '482913');
    expect(saved.at, bank.receivedAt);
    expect(saved.expires, bank.receivedAt.add(const Duration(minutes: 10)));
  });

  test(
    'the newest fresh code wins; the same one is not written again',
    () async {
      arrive(200, const Duration(minutes: 6), code: '111111');
      final newer = arrive(
        201,
        const Duration(minutes: 1),
        code: 'X7KQ2P',
        name: 'Lumen Shop',
      );
      await latest.update(now: now);
      await latest.update(now: now.add(const Duration(minutes: 1)));
      expect(slot.saved.single.messageId, newer.id);
      expect(slot.saved.single.sender, 'Lumen Shop');
      expect(slot.clears, 0);
    },
  );

  test('nothing is written when no code was found in the email', () async {
    arrive(200, const Duration(minutes: 1), code: '');
    arrive(201, const Duration(minutes: 1)); // not looked at yet
    await latest.update(now: now);
    expect(slot.saved, isEmpty);
    expect(slot.clears, 1, reason: 'anything older is let go of');
  });

  test('cleared once older than 10 minutes', () async {
    arrive(200, const Duration(minutes: 2), code: '482913');
    await latest.update(now: now);
    expect(slot.saved, hasLength(1));
    await latest.update(now: now.add(const Duration(minutes: 7)));
    expect(slot.clears, 0, reason: '9 minutes old: still offered');
    await latest.update(now: now.add(const Duration(minutes: 8, seconds: 1)));
    expect(slot.clears, 1);
    expect(
      LatestCode.find(app.store, now: now.add(const Duration(hours: 1))),
      isNull,
    );
  });

  test('cleared when the email is deleted', () async {
    final bank = arrive(200, const Duration(minutes: 2), code: '482913');
    await latest.update(now: now);
    expect(slot.saved, hasLength(1));
    MailActions(app.store).delete([bank]);
    await latest.update(now: now);
    expect(slot.clears, 1);
  });

  test('an older fresh code takes over when the newest is deleted', () async {
    final older = arrive(200, const Duration(minutes: 5), code: '111111');
    final newer = arrive(201, const Duration(minutes: 1), code: '222222');
    await latest.update(now: now);
    MailActions(app.store).delete([newer]);
    await latest.update(now: now);
    expect([for (final s in slot.saved) s.messageId], [newer.id, older.id]);
  });

  test('offered again while the tile is not added', () async {
    slot.keeps = false;
    arrive(200, const Duration(minutes: 2), code: '482913');
    await latest.update(now: now);
    slot.keeps = true;
    await latest.update(now: now);
    expect(slot.saved, hasLength(1));
  });

  test('nothing is kept while the app lock is on', () async {
    arrive(200, const Duration(minutes: 2), code: '482913');
    app.store.settings.write('lock.enabled', 'on');
    await latest.update(now: now);
    expect(slot.saved, isEmpty);
    expect(slot.clears, 1);
  });

  test('Android: what goes over the channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('citusmail/latest-code');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'save' ? true : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final at = DateTime.utc(2026, 11, 26, 14, 28);
    const android = AndroidLatestCodeSlot();
    expect(
      await android.save(
        FreshCode(
          messageId: MessageId(7),
          sender: 'Northwind Bank',
          code: '482913',
          at: at,
        ),
      ),
      isTrue,
    );
    await android.clear();
    expect(calls.map((c) => c.method), ['save', 'clear']);
    expect(calls.first.arguments, {
      'sender': 'Northwind Bank',
      'code': '482913',
      'at': at.millisecondsSinceEpoch,
      'expires': at.add(const Duration(minutes: 10)).millisecondsSinceEpoch,
    });
  });

  test('elsewhere: no tile, nothing to keep or ask', () async {
    expect(LatestCode.available, isFalse);
    expect(await LatestCode.requestTile(), TileRequest.unsupported);
    // Without a slot, update does nothing (and does not throw).
    arrive(200, const Duration(minutes: 2), code: '482913');
    await LatestCode(app.store).update(now: now);
  });
}
