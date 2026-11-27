// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:citusmail/src/features/reader/ui/attachment_saver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// On a phone, saved files go to the public Download/Citusmail folder the
/// Files app shows, not to the app's hidden folder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('citusmail/files');
  final calls = <MethodCall>[];
  late Directory temp;

  setUp(() {
    calls.clear();
    temp = Directory.systemTemp.createTempSync('saver');
    AttachmentSaver.isAndroid = () => true;
    final original = AttachmentSaver.downloads;
    addTearDown(() => AttachmentSaver.downloads = original);
  });
  tearDown(() {
    AttachmentSaver.isAndroid = () => Platform.isAndroid;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    temp.deleteSync(recursive: true);
  });

  void answer(Object? Function(MethodCall call) reply) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return reply(call);
          });

  test('Android: into Download/Citusmail, under the name it got', () async {
    // The system picked a free name: nothing is overwritten.
    answer((_) => 'Ticket (1).pdf');
    final saved = await AttachmentSaver.saveBytes('Ticket.pdf', [1, 2, 3]);
    expect(saved.path, 'Download/Citusmail/Ticket (1).pdf');
    final call = calls.single;
    expect(call.method, 'saveToDownloads');
    final args = call.arguments as Map;
    expect(args['name'], 'Ticket.pdf');
    expect(args['mime'], 'application/pdf');
    expect(args['bytes'], [1, 2, 3]);
  });

  test('types the Files app opens by', () async {
    answer((_) => 'x');
    for (final (name, mime) in [
      ('invite.ics', 'text/calendar'),
      ('Message.eml', 'message/rfc822'),
      ('photo.JPG', 'image/jpeg'),
      ('unknown.xyz', 'application/octet-stream'),
      ('noextension', 'application/octet-stream'),
    ]) {
      calls.clear();
      await AttachmentSaver.saveBytes(name, const [0]);
      expect((calls.single.arguments as Map)['mime'], mime, reason: name);
    }
  });

  test('older Android: the app\'s own Downloads folder, as before', () async {
    answer((_) => null);
    AttachmentSaver.downloads = () async => temp;
    final saved = await AttachmentSaver.saveBytes('Ticket.pdf', [7]);
    expect(saved.path, startsWith(temp.path));
    expect(File(saved.path).readAsBytesSync(), [7]);
  });
}
