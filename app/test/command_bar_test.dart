// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:citusmail/src/mail/commands.dart';
import 'package:citusmail/src/ui/appearance.dart';
import 'package:citusmail/src/ui/citusmail_theme.dart';
import 'package:citusmail/src/ui/command_bar.dart';
import 'package:citusmail/src/ui/discover_page.dart';
import 'package:citusmail/src/ui/features.dart';
import 'package:citusmail/src/ui/mail_shell.dart';
import 'package:citusmail/src/ui/settings_catalog.dart';
import 'package:citusmail/src/ui/settings_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// Ctrl+K: one box that finds emails, folders, settings and actions.
void main() {
  group('matching', () {
    double? score(
      String query,
      String title, [
      List<String> words = const [],
    ]) => CommandMatch.score(query, title, words: words);

    test('word starts, in any order, any case', () {
      expect(score('arch', 'Archive'), isNotNull);
      expect(score('ARCH', 'Archive'), isNotNull);
      expect(score('read mark', 'Mark as read'), isNotNull);
      expect(score('chive', 'Archive'), isNotNull, reason: 'inside a word');
      expect(score('trash', 'Delete', ['trash', 'bin']), isNotNull);
      expect(score('zzqx', 'Archive'), isNull);
      expect(score('', 'Archive'), isNull);
      expect(score('mark read zzqx', 'Mark as read'), isNull);
    });

    test('accents count as plain letters', () {
      expect(score('cafe', 'Café orders'), isNotNull);
      expect(score('café', 'Cafe orders'), isNotNull);
      expect(score('reunion', 'Réunion'), isNotNull);
      expect(CommandMatch.fold('Ångström Straße'), 'angstrom strasse');
    });

    test('a small typo is fine', () {
      expect(score('archve', 'Archive'), isNotNull);
      expect(score('setings', 'Settings'), isNotNull);
      expect(score('projcets', 'Projects'), isNotNull, reason: 'swapped');
      expect(score('fowrard', 'Forward'), isNotNull);
      expect(score('xrchive', 'Archive'), isNull, reason: 'not the first');
    });

    test('the name first, then other words', () {
      final name = score('arch', 'Archive')!;
      final other = score('arch', 'Search all mail', ['archive'])!;
      expect(name, greaterThan(other));
      expect(score('inbox', 'Inbox')!, greaterThan(score('inbox', 'Inboxes')!));
    });
  });

  late TestApp app;
  setUp(() async => app = await TestApp.create());
  tearDown(() async {
    Appearance.theme.value = ThemeMode.system;
    await app.dispose();
  });

  test('recent commands: the last 8, newest first, ids only', () {
    final history = CommandHistory(app.store);
    expect(history.ids, isEmpty);
    for (var i = 0; i < 10; i++) {
      history.used('go.folder.$i');
    }
    history.used('go.folder.5');
    expect(history.ids, hasLength(8));
    expect(history.ids.first, 'go.folder.5');
    expect(history.ids.where((i) => i == 'go.folder.5'), hasLength(1));
    expect(app.store.settings.read(CommandHistory.key), isNot(contains(' ')));
  });

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  var addedAccount = 0;

  Future<void> shell(
    WidgetTester tester, {
    Size at = const Size(1440, 900),
    bool dark = false,
  }) async {
    size(tester, at);
    addedAccount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: CitusmailTheme.light(),
        darkTheme: CitusmailTheme.dark(),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: MailShell(
          notifications: false,
          services: app.services,
          onAddAccount: () => addedAccount++,
          onAccountsChanged: () {},
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets real isolates (worker, message parsing) finish.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  Future<void> ctrlK(WidgetTester tester) async {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final modifier = mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byType(CommandBarDialog),
        matching: find.byType(TextField),
      ),
      text,
    );
    await tester.pumpAndSettle();
  }

  Future<void> openHello(WidgetTester tester) async {
    await tester.tap(find.text('Hello there').first);
    await settle(tester);
  }

  final bar = find.byType(CommandBarDialog);

  /// The dialog's box.
  final box = find.descendant(of: bar, matching: find.byType(Material)).first;

  /// A result row, by the start of what screen readers hear.
  Finder row(String start) => find.descendant(
    of: bar,
    matching: find.bySemanticsLabel(RegExp('^${RegExp.escape(start)}')),
  );

  bool highlighted(WidgetTester tester, Finder row) =>
      tester.widget<Semantics>(row).properties.selected ?? false;

  testWidgets('Ctrl+K opens it, Esc closes it, Ctrl+K again too', (
    tester,
  ) async {
    await shell(tester);
    await ctrlK(tester);
    expect(bar, findsOneWidget);
    expect(tester.getSize(box).width, CommandBarDialog.width);
    await key(tester, LogicalKeyboardKey.escape);
    expect(bar, findsNothing);

    await ctrlK(tester);
    expect(bar, findsOneWidget);
    await ctrlK(tester);
    expect(bar, findsNothing);

    // Also while typing in the search field.
    await tester.tap(find.widgetWithText(TextField, 'Search mail'));
    await tester.pump();
    await ctrlK(tester);
    expect(bar, findsOneWidget);
  });

  testWidgets('Cmd+K on a Mac', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await shell(tester);
    await ctrlK(tester);
    expect(bar, findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('phones: the keys do nothing', (tester) async {
    await shell(tester, at: const Size(390, 844));
    await ctrlK(tester);
    expect(bar, findsNothing);
  });

  testWidgets('finds an action, a folder, a setting and an email', (
    tester,
  ) async {
    await shell(tester);
    await openHello(tester);
    await ctrlK(tester);

    await type(tester, 'archive');
    expect(row('Archive, On the open email, Actions'), findsOneWidget);

    await type(tester, 'projects');
    expect(row('Projects, Folder, Go to'), findsOneWidget);

    await type(tester, 'dark mode');
    expect(row('Theme, Appearance, Settings'), findsOneWidget);

    await type(tester, 'lunch');
    expect(row('Lunch?, Carol'), findsOneWidget);
    expect(row('Search all mail for “lunch”'), findsOneWidget);
    // The search is the last row.
    expect(
      tester.getTopLeft(row('Search all mail')).dy,
      greaterThan(tester.getTopLeft(row('Lunch?')).dy),
    );
  });

  testWidgets('Enter archives, with Undo', (tester) async {
    await shell(tester);
    await openHello(tester);
    await ctrlK(tester);
    await type(tester, 'archive');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // The next email opens.
    await settle(tester);
    expect(bar, findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Hello there'), findsNothing, reason: 'archived');
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(find.text('Hello there'), findsWidgets, reason: 'back');
  });

  testWidgets('Enter opens a folder', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'projects');
    await key(tester, LogicalKeyboardKey.enter);
    expect(bar, findsNothing);
    expect(find.byTooltip('Back to Inbox'), findsOneWidget);
    expect(find.text('Projects'), findsNWidgets(2), reason: 'and the title');
  });

  testWidgets('Enter opens Settings at the setting', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'dark mode');
    await key(tester, LogicalKeyboardKey.enter);
    final page = tester.widget<SettingsPage>(find.byType(SettingsPage));
    expect(page.show, 'theme');
    final mark = tester.widget<SettingHighlight>(
      find
          .ancestor(
            of: find.text('Theme'),
            matching: find.byType(SettingHighlight),
          )
          .first,
    );
    expect(mark.on, isTrue);
  });

  testWidgets('Enter opens the email', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'hello');
    expect(row('Hello there'), findsOneWidget);
    await tester.tap(row('Hello there'));
    await settle(tester);
    expect(bar, findsNothing);
    expect(find.textContaining('Visible'), findsWidgets, reason: 'its body');
  });

  testWidgets('"Search all mail" searches', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'deals');
    await tester.tap(row('Search all mail'));
    await settle(tester);
    expect(find.text('Results for "deals"'), findsOneWidget);
  });

  testWidgets('New message, Add account', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'add acc');
    await key(tester, LogicalKeyboardKey.enter);
    expect(addedAccount, 1);
  });

  testWidgets('what doesn\'t apply isn\'t there', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    // Nothing open, nothing selected: no actions at all.
    await type(tester, 'archive');
    expect(find.bySemanticsLabel(RegExp(', Actions')), findsNothing);
    await key(tester, LogicalKeyboardKey.escape);

    await openHello(tester);
    await ctrlK(tester);
    await type(tester, 'reply');
    expect(row('Reply, To the open email, Actions, shortcut R'), findsOne);
    // The AI assistant is off.
    await type(tester, 'summarise');
    expect(find.bySemanticsLabel(RegExp('^Summarise')), findsNothing);
    await type(tester, 'translate');
    expect(find.bySemanticsLabel(RegExp(', Actions')), findsNothing);
    // This account has no Trash folder, so deleting would be for good:
    // like the Delete key, the bar leaves that to the reader (it asks).
    await type(tester, 'delete');
    expect(row('Delete, On the open email, Actions, shortcut #'), findsNothing);
  });

  testWidgets('recent commands first when the box is empty', (tester) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'pins');
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('Pins'), findsWidgets);
    await ctrlK(tester);
    final recent = row('Pins, Recent');
    expect(recent, findsOneWidget);
    expect(highlighted(tester, recent), isTrue, reason: 'first');
    // Only command ids are kept.
    expect(CommandHistory(app.store).ids, ['go.pins']);

    // Emails and searches aren't kept.
    await type(tester, 'lunch');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(CommandHistory(app.store).ids, ['go.pins']);
  });

  testWidgets('arrows move, Tab goes to the next group, Enter runs', (
    tester,
  ) async {
    await shell(tester);
    await ctrlK(tester);
    await type(tester, 'in');
    final rows = find.descendant(
      of: bar,
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.role == SemanticsRole.listItem,
      ),
    );
    String label(int i) =>
        tester.widget<Semantics>(rows.at(i)).properties.label!;
    int current() {
      for (var i = 0; i < rows.evaluate().length; i++) {
        if (tester.widget<Semantics>(rows.at(i)).properties.selected ?? false) {
          return i;
        }
      }
      return -1;
    }

    expect(current(), 0);
    expect(label(0), startsWith('Inbox, '));
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(current(), 1);
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(current(), 0, reason: 'stays at the top');

    // Tab: the first row of the next group.
    final first = label(0).split(', ');
    await key(tester, LogicalKeyboardKey.tab);
    final group = label(current());
    expect(current(), greaterThan(0));
    expect(group, isNot(contains(first[first.length - 1])));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(current(), 0, reason: 'back');
    // The field keeps the keyboard.
    final field = tester.widget<TextField>(
      find.descendant(of: bar, matching: find.byType(TextField)),
    );
    expect(field.focusNode!.hasFocus, isTrue);

    await key(tester, LogicalKeyboardKey.enter);
    expect(bar, findsNothing);
  });

  testWidgets('screen readers: a labelled field, a list of rows', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await shell(tester);
    await openHello(tester);
    await ctrlK(tester);
    expect(
      find.descendant(
        of: bar,
        matching: find.bySemanticsLabel(RegExp('Command bar')),
      ),
      findsOneWidget,
    );
    await type(tester, 'archive');
    expect(
      row('Archive, On the open email, Actions, shortcut E'),
      findsOneWidget,
    );
    final list = find.descendant(
      of: bar,
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.role == SemanticsRole.list,
      ),
    );
    expect(list, findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('Actions')), findsOne);
    semantics.dispose();
  });

  for (final width in [1024.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('fits at $width wide${dark ? ', dark' : ''}', (tester) async {
        await shell(tester, at: Size(width, 768), dark: dark);
        await openHello(tester);
        await ctrlK(tester);
        expect(tester.takeException(), isNull);
        await type(tester, 'a');
        expect(tester.takeException(), isNull);
        await type(
          tester,
          'a very long thing to look for that matches nothing',
        );
        expect(tester.takeException(), isNull);
        expect(tester.getSize(box).width, lessThanOrEqualTo(640));
      });
    }
  }

  group('ways to it', () {
    testWidgets('in All features, and it opens', (tester) async {
      await shell(tester);
      expect(Features.byId('commandBar'), isNotNull);
      expect(
        Features.available(android: true).map((f) => f.id),
        isNot(contains('commandBar')),
      );
      await tester.tap(find.text('All features'));
      await tester.pumpAndSettle();
      expect(find.byType(DiscoverPage), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(RegExp('Open Command bar')));
      await tester.pumpAndSettle();
      expect(find.byType(DiscoverPage), findsNothing);
      expect(bar, findsOneWidget);
    });

    test('in the settings search, desktop only', () {
      expect(
        SettingsCatalog.search('command bar', android: false).first.id,
        CommandBar.settingId,
      );
      expect(
        SettingsCatalog.search('command', android: true).map((e) => e.id),
        isNot(contains(CommandBar.settingId)),
      );
    });

    testWidgets('in the ? help', (tester) async {
      await shell(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.text('Ctrl+K'), findsOneWidget);
      await tester.tap(find.text('Open the command bar'));
      await tester.pumpAndSettle();
      expect(find.text('Keyboard shortcuts'), findsNothing);
      expect(bar, findsOneWidget);
    });
  });
}
