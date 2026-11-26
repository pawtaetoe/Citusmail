// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Picking messages and moving between places, on their own: the
// selection and location controllers without the mail screen.

import 'package:citusmail/src/features/inbox/state/location_controller.dart';
import 'package:citusmail/src/features/inbox/state/mail_location.dart';
import 'package:citusmail/src/features/inbox/state/message_list_model.dart';
import 'package:citusmail/src/features/inbox/state/selection_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mail_store/mail_store.dart';

import 'support/test_app.dart';

void main() {
  late TestApp app;
  late MessageListModel list;
  late SelectionController selection;
  late LocationController location;
  StoredMessage? open;
  late int refreshes;

  setUp(() async {
    app = await TestApp.create();
    open = null;
    refreshes = 0;
    list = MessageListModel(app.store);
    selection = SelectionController(app.store, list, openMessage: () => open);
    location = LocationController(
      app.store,
      app.services.worker,
      list,
      selection,
      refresh: () => refreshes++,
    );
    final inbox = app.store.mailboxes.inbox(
      app.store.accounts.all().single.id,
    )!;
    location.goTo(FolderLocation(inbox.id, inbox.accountId));
  });
  tearDown(() {
    location.dispose();
    selection.dispose();
    list.dispose();
    return app.dispose();
  });

  group('SelectionController', () {
    test('toggle, range, all and clear', () {
      final visible = list.visible;
      expect(visible.length, 5);
      expect(selection.selecting, isFalse);

      selection.toggle(visible[1]);
      expect(selection.selection.value, {visible[1].id});
      selection.selectRange(visible[3]);
      expect(selection.selection.value, {
        visible[1].id,
        visible[2].id,
        visible[3].id,
      });
      selection.toggle(visible[2]);
      expect(selection.selection.value, {visible[1].id, visible[3].id});

      selection.selectAllVisible();
      expect(selection.selection.value, {for (final m in visible) m.id});
      selection.clear();
      expect(selection.selection.value, isEmpty);
      expect(selection.selecting, isFalse);
    });

    test('a range with nothing selected picks just the one', () {
      final visible = list.visible;
      selection.selectRange(visible[2]);
      expect(selection.selection.value, {visible[2].id});
    });

    test('clearing nothing doesn\'t notify', () {
      var notified = 0;
      selection.selection.addListener(() => notified++);
      selection.clear();
      expect(notified, 0);
    });

    test('targets: the selected messages, else the open one', () {
      final visible = list.visible;
      expect(selection.targets, isEmpty);
      open = visible.first;
      expect(selection.targets.single.id, visible.first.id);
      selection.toggle(visible[2]);
      selection.toggle(visible[3]);
      expect(
        {for (final m in selection.targets) m.id},
        {visible[2].id, visible[3].id},
      );
    });
  });

  group('LocationController', () {
    test('going somewhere clears the selection and shows its list', () {
      selection.toggle(list.visible.first);
      location.goTo(const InboxLocation());
      expect(location.location.value, const InboxLocation());
      expect(selection.selection.value, isEmpty);
      expect(list.showsSections, isTrue);
    });

    test('search trims, and an empty search is the inbox', () {
      location.search('  lunch ');
      expect(location.location.value, const SearchLocation('lunch'));
      expect(list.visible.single.subject, 'Lunch?');
      location.searchExactly('lunch');
      expect(
        location.location.value,
        const SearchLocation('lunch', exact: true),
      );
      location.search('   ');
      expect(location.location.value, const InboxLocation());
    });

    test('loading more offline keeps the list and can try again', () async {
      await location.loadMore();
      expect(list.loadingOlder, isFalse);
      expect(list.visible.length, 5);
    });

    test('a search has no older mail to fetch', () async {
      location.search('lunch');
      await location.loadMore();
      expect(list.reachedEnd, isTrue);
    });
  });
}
