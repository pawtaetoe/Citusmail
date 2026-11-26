// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import 'package:citusmail/src/core/state/validation.dart';
import 'package:citusmail/src/core/theme/citusmail_theme.dart';
import 'package:citusmail/src/features/compose/state/compose_controller.dart';
import 'package:citusmail/src/features/compose/state/compose_fields.dart';
import 'package:citusmail/src/features/compose/ui/compose_page.dart';
import 'package:citusmail/src/features/inbox/state/mail_controller.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_compose/mail_compose.dart';

import 'support/test_app.dart';

/// A picked file that says how large it is, and fails the test if it is
/// read.
final class _File extends XFile {
  _File(String name, this.size, {this.read = true})
    : super.fromData(Uint8List(read ? size : 0), name: name, path: name);

  final int size;
  final bool read;

  @override
  Future<int> length() async => size;

  @override
  Future<Uint8List> readAsBytes() async {
    if (!read) fail('$name was read');
    return super.readAsBytes();
  }
}

void main() {
  group('MailtoLink', () {
    MailtoLink valid(String link) =>
        switch (MailtoLink.parse(Uri.parse(link))) {
          Valid(:final value) => value,
          Invalid(:final reason) => fail(reason),
        };
    String? invalid(String link) => MailtoLink.parse(Uri.parse(link)).reason;

    test('addresses and a subject', () {
      final link = valid(
        'mailto:ann@x.example,bob@y.example?subject=Hi%20there',
      );
      expect(
        [for (final a in link.to) a.address],
        ['ann@x.example', 'bob@y.example'],
      );
      expect(link.subject, 'Hi there');
      expect(valid('MAILTO:j@m%C3%BCnchen.de').to.single.domain, 'münchen.de');
      expect(valid('mailto:?subject=Only').to, isEmpty);
    });

    test('a subject stays one line', () {
      final link = valid(
        'mailto:ann@x.example?subject=Hi%0D%0ABcc:%20eve@evil.example',
      );
      expect(link.subject, 'Hi  Bcc: eve@evil.example');
      expect(link.to.single.address, 'ann@x.example');
    });

    test('addresses mail can\'t go to are left out', () {
      final link = valid('mailto:ann@x.example,j%C3%BCrgen@example.com,nope');
      expect([for (final a in link.to) a.address], ['ann@x.example']);
    });

    test('damaged, too long, too many or not an email link', () {
      // Not UTF-8 once decoded: this threw out of the tap before.
      expect(invalid('mailto:%C3@x.example'), 'That email link is damaged.');
      expect(
        invalid('mailto:ann@x.example?subject=%FF'),
        'That email link is damaged.',
      );
      expect(
        invalid('mailto:ann@x.example?subject=${'x' * 9000}'),
        'That email link is too long.',
      );
      expect(
        invalid(
          'mailto:${[for (var i = 0; i < 101; i++) 'p$i@x.example'].join(',')}',
        ),
        'That email link has too many addresses.',
      );
      expect(invalid('https://x.example'), 'That isn\'t an email link.');
    });
  });

  group('attachments', () {
    test('file names lose folders and control characters', () {
      expect(ComposeFields.fileName('../../etc/passwd'), 'passwd');
      expect(ComposeFields.fileName(r'C:\Users\me\report.pdf'), 'report.pdf');
      expect(ComposeFields.fileName('a\r\nb.txt'), 'a  b.txt');
      expect(ComposeFields.fileName('..'), 'attachment');
      expect(ComposeFields.fileName(''), 'attachment');
      final long = ComposeFields.fileName('${'ü' * 300}.pdf');
      expect(long.runes.length, ComposeFields.maxFileName);
      expect(long, endsWith('.pdf'));
    });

    test('a file larger than what can be sent is refused by its size', () {
      expect(ComposeFields.attachment('a.pdf', 1000).valueOrNull, 'a.pdf');
      const limit = OutgoingMessages.defaultMaxAttachmentBytes;
      expect(ComposeFields.attachment('a.pdf', limit).isValid, isTrue);
      expect(
        ComposeFields.attachment('a.pdf', limit + 1).reason,
        'a.pdf is too large to send (attachments can be at most 18.0 MB in '
        'all).',
      );
      expect(
        ComposeFields.attachment('b.pdf', 10, alreadyAttached: limit).isValid,
        isFalse,
      );
    });
  });

  group('compose window', () {
    late TestApp app;
    setUp(() async => app = await TestApp.create());
    tearDown(() => app.dispose());

    Future<ComposeController> show(
      WidgetTester tester,
      Future<List<XFile>> Function() pick,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ComposeController(
        app.services,
        Draft(accountId: app.store.accounts.all().single.id),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: CitusmailTheme.light(),
          home: ComposePage(controller: controller, pickFiles: pick),
        ),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('a file too large to send is never read, and says why', (
      tester,
    ) async {
      final c = await show(
        tester,
        () async => [
          _File('notes.txt', 12),
          _File('holiday.mp4', 40 * 1024 * 1024, read: false),
        ],
      );
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pump();
      await tester.pump();
      expect([for (final a in c.draft.attachments) a.fileName], ['notes.txt']);
      expect(find.textContaining('holiday.mp4 is too large'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a pasted subject stays one line', (tester) async {
      final c = await show(tester, () async => []);
      final subject = find.widgetWithText(TextField, 'Subject');
      await tester.enterText(subject, 'Plans\rBcc: eve@evil.example');
      await tester.pump();
      expect(c.draft.subject, 'Plans Bcc: eve@evil.example');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  test('a damaged mailto link is a notice, not a crash', () async {
    final app = await TestApp.create();
    addTearDown(app.dispose);
    final controller = MailController(app.services);
    final notices = <String>[];
    final drafts = <Draft>[];
    controller
      ..onNotice = ((message, {undo}) => notices.add(message))
      ..onCompose = drafts.add;
    controller.composeTo(Uri.parse('mailto:%C3@x.example'));
    expect(notices, ['That email link is damaged.']);
    expect(drafts, isEmpty);
    controller.composeTo(Uri.parse('mailto:ann@x.example?subject=Hi'));
    expect(drafts.single.to.single.address, 'ann@x.example');
    expect(drafts.single.subject, 'Hi');
    controller.dispose();
  });
}
