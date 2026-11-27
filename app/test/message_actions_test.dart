// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Pin, read, archive, move and delete with Undo, and the user's folders,
// on their own: the actions and folder controllers without the mail
// screen.

import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/organise/state/folder_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'support/controllers.dart';
import 'support/test_app.dart';

void main() {
  late TestApp app;
  late Controllers c;
  setUp(() async {
    app = await TestApp.create();
    c = Controllers(app);
  });
  tearDown(() {
    c.dispose();
    return app.dispose();
  });

  bool inInbox(String subject) => c.store.messages
      .list(MessageQuery(mailboxIds: [c.box('INBOX').id]))
      .any((m) => m.subject == subject);

  group('MessageActions', () {
    test('one pinned quietly; several with Undo', () {
      c.actions.togglePin([c.message('Lunch?')]);
      expect(c.message('Lunch?').flags.flagged, isTrue);
      expect(c.notices, isEmpty);

      final two = [c.message('Lunch?'), c.message('Weekly deals')];
      c.actions.togglePin(two);
      expect(c.message('Weekly deals').flags.flagged, isTrue);
      expect(c.lastNotice, 'Pinned (2)');
      c.undoLast();
      expect(c.message('Weekly deals').flags.flagged, isFalse);
    });

    test('read and unread; the selection ends', () {
      final lunch = c.message('Lunch?');
      c.selection.toggle(lunch);
      c.actions.toggleRead([lunch]);
      expect(c.message('Lunch?').flags.seen, isTrue);
      expect(c.selection.selection.value, isEmpty);
      c.actions.toggleRead([c.message('Lunch?')]);
      expect(c.message('Lunch?').flags.seen, isFalse);
    });

    test('mark all read always offers Undo', () {
      c.actions.markAllRead([c.message('Lunch?')]);
      expect(c.lastNotice, 'Marked as read (1)');
      c.undoLast();
      expect(c.message('Lunch?').flags.seen, isFalse);
      c.actions.markAllRead(const []);
      expect(c.notices, hasLength(1), reason: 'nothing to mark');
    });

    test('archive with Undo', () {
      final lunch = c.message('Lunch?');
      expect(c.actions.archiveFor(lunch)?.encodedName, 'Archive');
      c.actions.archive([lunch]);
      expect(c.lastNotice, 'Archived');
      expect(inInbox('Lunch?'), isFalse);
      c.undoLast();
      expect(inInbox('Lunch?'), isTrue);
    });

    test('the open message leaving opens the next one', () async {
      final visible = c.list.visible;
      final first = visible.first;
      await c.reader.open(first);
      c.actions.moveTo([first], c.box('Projects'));
      expect(c.lastNotice, 'Moved to Projects');
      await Future<void>.delayed(Duration.zero);
      expect(c.reader.selected?.id, visible[1].id);
      expect(c.list.visible.map((m) => m.id), isNot(contains(first.id)));
    });

    test('no Trash: deleting is for good', () {
      final lunch = c.message('Lunch?');
      expect(c.actions.isInTrash(lunch), isFalse);
      expect(c.actions.deletesForever(lunch), isTrue);
      c.actions.delete([lunch]);
      expect(c.lastNotice, 'Deleted');
    });

    test('"Not spam" moves Junk mail back to the inbox', () {
      c.store.messages.upsertSummaries(c.box('Junk').id, [
        MessageSummary(
          uid: 7,
          receivedAt: DateTime.utc(2026, 10, 21),
          subject: 'Not junk',
          from: const MailAddress(localPart: 'erin', domain: 'x.example'),
        ),
      ]);
      final junk = c.message('Not junk');
      expect(c.actions.isInJunk(junk), isTrue);
      c.actions.notSpam([junk, c.message('Weekly deals')]);
      expect(c.lastNotice, 'Not spam. Moved to Inbox.');
      expect(c.store.messages.byId(junk.id), isNull);
    });

    test('"Always move here" adds a rule and moves', () {
      final projects = c.box('Projects');
      c.actions.moveAlways(c.message('Lunch?'), projects);
      expect(c.lastNotice, 'Moved to Projects');
      expect(inInbox('Lunch?'), isFalse);
      final rules = c.store.folderRules.forMailbox(projects.id);
      expect(rules.single.value, 'carol@x.example');
    });

    test('a section marked read, the account being viewed only', () {
      c.location.goTo(InboxLocation(accountId: c.accountId));
      c.actions.markSectionRead(SmartSection.general);
      expect(c.lastNotice, startsWith('Marked as read ('));
    });
  });

  group('FolderController', () {
    late FolderController folders;
    setUp(() {
      folders = FolderController(
        c.store,
        app.services.worker,
        c.location,
        c.counts,
      );
    });
    tearDown(() => folders.dispose());

    test('rules only for folders that can hold them', () {
      expect(FolderController.canHaveRules(c.box('Projects')), isTrue);
      expect(FolderController.canHaveRules(c.box('INBOX')), isFalse);
      expect(FolderController.canHaveRules(c.box('Sent')), isFalse);
      expect(FolderController.canHaveRules(c.box('Drafts')), isFalse);
    });

    test('move targets leave out the message\'s own folder', () {
      final targets = folders.moveTargets(c.message('Lunch?'));
      expect(targets.map((b) => b.encodedName), contains('Projects'));
      expect(targets.map((b) => b.encodedName), isNot(contains('INBOX')));
    });

    test('a rule is added, refused with a reason, and removed', () {
      final projects = c.box('Projects');
      expect(
        folders.addRule(projects, RuleField.fromAddress, 'not an address'),
        'Enter an email address.',
      );
      expect(
        folders.addRule(projects, RuleField.fromAddress, 'carol@x.example'),
        isNull,
      );
      final rule = folders.rulesFor(projects.id).single;
      folders.removeRule(rule);
      expect(folders.rulesFor(projects.id), isEmpty);
    });

    test('creating a folder offline says so', () async {
      expect(
        await folders.createFolder(c.accountId, 'Receipts'),
        'Folders can only be created while online.',
      );
      expect(c.location.location.value, const InboxLocation());
    });
  });
}
