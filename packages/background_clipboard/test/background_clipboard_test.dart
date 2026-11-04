// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:background_clipboard/background_clipboard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const plugin = MethodChannel('citusmail/background-clipboard');

  late List<MethodCall> pluginCalls;
  late List<MethodCall> flutterCalls;
  setUp(() {
    pluginCalls = [];
    flutterCalls = [];
    messenger.setMockMethodCallHandler(plugin, (call) async {
      pluginCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      flutterCalls.add(call);
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('Android: through the plugin, marked sensitive, with a toast', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await BackgroundClipboard.copy(
      '482913',
      label: 'Code',
      sensitive: true,
      confirmation: 'Code copied',
    );
    expect(flutterCalls, isEmpty);
    expect(pluginCalls.single.method, 'copy');
    expect(pluginCalls.single.arguments, {
      'text': '482913',
      'label': 'Code',
      'sensitive': true,
      'confirmation': 'Code copied',
    });
  });

  test('Android: no confirmation unless asked', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await BackgroundClipboard.copy('X7KQ2P');
    expect(
      (pluginCalls.single.arguments as Map).containsKey('confirmation'),
      isFalse,
    );
  });

  test('desktop: Flutter\'s clipboard', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await BackgroundClipboard.copy('482913', sensitive: true);
    expect(pluginCalls, isEmpty);
    expect(flutterCalls.single.method, 'Clipboard.setData');
    expect(flutterCalls.single.arguments, {'text': '482913'});
  });
}
