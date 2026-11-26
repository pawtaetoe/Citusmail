// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mail/mail_controller.dart';
import '../mail/mail_location.dart';
import 'app_icons.dart';
import 'ask_mail_panel.dart';
import 'citusmail_theme.dart';
import 'features.dart';
import 'message_list_pane.dart';
import 'motion.dart';
import 'reader_pane.dart';

/// The tabs of the phone layout, in the navigation bar's order.
enum PhoneTab { inbox, pins, found, folders }

/// The phone layout: search at the top of the inbox, a navigation bar at
/// the bottom (Inbox, Pins, Found, Folders) and New message above it.
///
/// An open message, or a folder opened from the Folders tab, covers the
/// tab, and pages opened from a tab are pushed on top as elsewhere: the
/// bar shows on the four tabs only. Back closes what covers a tab, then
/// goes from Pins, Found or Folders to the Inbox.
final class PhoneHome extends StatefulWidget {
  const PhoneHome({
    super.key,
    required this.controller,
    required this.searchFocus,
    required this.folders,
  });

  final MailController controller;

  /// The search field's focus (the "/" shortcut, a pull at the top).
  final FocusNode searchFocus;

  /// The Folders tab: the sidebar, laid out for it.
  final Widget folders;

  @override
  State<PhoneHome> createState() => _PhoneHomeState();
}

final class _PhoneHomeState extends State<PhoneHome>
    with SingleTickerProviderStateMixin {
  MailController get _c => widget.controller;

  late PhoneTab _tab = _c.location.value is PinsLocation
      ? PhoneTab.pins
      : PhoneTab.inbox;

  /// How much of the search bar shows: 1 in view, 0 slid away.
  late final AnimationController _search = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );

  /// How far the list has scrolled one way since it last turned.
  double _drift = 0;

  /// How far the list has been pulled down past its top, in this drag.
  double _pull = 0;

  /// Pulled far enough to focus search: once per drag.
  bool _pulled = false;

  /// How far a pull at the top goes before search is focused.
  static const _pullToSearch = 64.0;

  @override
  void initState() {
    super.initState();
    _c.location.addListener(_followLocation);
    widget.searchFocus.addListener(_searching);
  }

  @override
  void dispose() {
    _c.location.removeListener(_followLocation);
    widget.searchFocus.removeListener(_searching);
    _search.dispose();
    super.dispose();
  }

  /// Places shown from elsewhere (a search from Settings, Pins from a
  /// shortcut) show on their own tab.
  void _followLocation() {
    final tab = switch (_c.location.value) {
      PinsLocation() => PhoneTab.pins,
      SearchLocation() => PhoneTab.inbox,
      InboxLocation(accountId: null) when _tab == PhoneTab.pins =>
        PhoneTab.inbox,
      _ => _tab,
    };
    if (tab != _tab) setState(() => _tab = tab);
    // A new list starts at its top, search in view.
    _search.value = 1;
  }

  /// Search in view while typing in it (also after "/").
  void _searching() {
    if (widget.searchFocus.hasFocus) _search.value = 1;
  }

  /// What each tab shows when nothing covers it.
  static MailLocation _rootOf(PhoneTab tab) =>
      tab == PhoneTab.pins ? const PinsLocation() : const InboxLocation();

  /// Whether the tab is shown as it is (the bar is there), rather than a
  /// folder opened from it.
  bool _atRoot(MailLocation location) => switch (_tab) {
    PhoneTab.inbox =>
      location == const InboxLocation() || location is SearchLocation,
    PhoneTab.pins => location is PinsLocation,
    PhoneTab.found || PhoneTab.folders => location == const InboxLocation(),
  };

  void _select(PhoneTab tab) {
    widget.searchFocus.unfocus();
    setState(() => _tab = tab);
    final root = _rootOf(tab);
    // Inbox again while searching: back to the whole inbox.
    if (_c.location.value != root) _c.goTo(root);
    _search.value = 1;
  }

  void _back() {
    if (_c.selecting) {
      _c.clearSelection();
    } else if (_c.selected != null) {
      _c.closeMessage();
    } else if (!_atRoot(_c.location.value)) {
      _c.goTo(_rootOf(_tab));
    } else {
      _select(PhoneTab.inbox);
    }
  }

  void _hideSearch() {
    if (widget.searchFocus.hasFocus) return;
    // Screen readers move through the page; the bar stays put for them.
    if (MediaQuery.accessibleNavigationOf(context)) return;
    if (_search.status != AnimationStatus.reverse && _search.value > 0) {
      _search.reverse();
    }
  }

  void _showSearch() {
    if (_search.status != AnimationStatus.forward && _search.value < 1) {
      _search.forward();
    }
  }

  /// The search bar slides away while the list scrolls down and comes
  /// back as soon as it scrolls up; a pull down at the top focuses it.
  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    // The list's, not those of an answer above it.
    if (n.context?.findAncestorWidgetOfExactType<AskMailPanel>() != null) {
      return false;
    }
    final m = n.metrics;
    switch (n) {
      case ScrollStartNotification():
        _pull = 0;
        _pulled = false;
      case ScrollUpdateNotification(:final scrollDelta?):
        if (m.pixels <= m.minScrollExtent) {
          _drift = 0;
          _showSearch();
          // Bouncing scroll views (iOS) go past their top.
          if (n.dragDetails != null) _pulledBy(m.minScrollExtent - m.pixels);
          break;
        }
        if (scrollDelta.sign != _drift.sign) _drift = 0;
        _drift += scrollDelta;
        if (_drift > 24 && m.pixels > 56) {
          _hideSearch();
        } else if (_drift < -8) {
          _showSearch();
        }
      case OverscrollNotification(:final overscroll, dragDetails: _?)
          when overscroll < 0:
        _pull += -overscroll;
        _pulledBy(_pull);
      case _:
    }
    return false;
  }

  void _pulledBy(double distance) {
    if (_pulled || distance < _pullToSearch) return;
    _pulled = true;
    _search.value = 1;
    widget.searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _c.reader,
      _c.selection,
      _c.location,
      widget.searchFocus,
    ]),
    builder: (context, _) {
      final location = _c.location.value;
      final open = _c.selected != null;
      final selecting = _c.selecting;
      final atRoot = _atRoot(location);
      final reader = ReaderPane(
        controller: _c,
        showBack: true,
        toolbarAtBottom: true,
        replyBar: false,
      );
      final hub = atRoot && _tab == PhoneTab.found
          ? FoundHub(controller: _c)
          : atRoot && _tab == PhoneTab.folders
          ? widget.folders
          : null;
      final Widget body;
      if (hub != null) {
        body = open ? reader : hub;
      } else {
        // The row grows into the message, and back; the list stays where
        // it was underneath.
        body = OpenTransition(
          message: _c.selected?.id,
          list: _list(search: atRoot && _tab == PhoneTab.inbox),
          reader: reader,
        );
      }
      final Widget? bottom;
      if (open) {
        bottom = _BottomBar(child: ReaderControls(controller: _c));
      } else if (selecting) {
        // The actions for what is selected take the bar's place.
        bottom = _BottomBar(child: MessageSelectionControls(controller: _c));
      } else if (atRoot) {
        bottom = _navigationBar();
      } else {
        bottom = null;
      }
      // Over the lists of mail, not while typing a search.
      final compose =
          !open &&
          !selecting &&
          !(atRoot && (_tab == PhoneTab.found || _tab == PhoneTab.folders)) &&
          !widget.searchFocus.hasFocus;
      return PopScope(
        canPop: !open && !selecting && atRoot && _tab == PhoneTab.inbox,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: Scaffold(
          body: SafeArea(left: false, child: body),
          bottomNavigationBar: bottom,
          floatingActionButton: compose ? _ComposeButton(_c.compose) : null,
        ),
      );
    },
  );

  Widget _list({required bool search}) {
    final pane = MessageListPane(
      controller: _c,
      onCompose: null,
      searchFocus: widget.searchFocus,
      controlsAtBottom: true,
      tabRoot: _rootOf(_tab),
      // The New message button floats over the end of the list.
      endSpace: 88,
    );
    if (!search) return pane;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ScrollConfiguration(
        behavior: _PullBehavior(ScrollConfiguration.of(context)),
        child: ColoredBox(
          color: ListColors.of(context).background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRect(
                child: AnimatedBuilder(
                  animation: _search,
                  builder: (context, child) => Align(
                    alignment: Alignment.bottomCenter,
                    heightFactor: Curves.easeOut.transform(_search.value),
                    child: ExcludeSemantics(
                      excluding: _search.value == 0,
                      child: child,
                    ),
                  ),
                  child: MessageSearchBar(
                    controller: _c,
                    searchFocus: widget.searchFocus,
                  ),
                ),
              ),
              Expanded(child: pane),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navigationBar() => ValueListenableBuilder(
    valueListenable: _c.counts,
    builder: (context, counts, _) {
      final unread = counts.inboxUnread;
      Widget inbox(IconData icon) => Badge(
        isLabelVisible: unread > 0,
        backgroundColor: CitusPalette.citrus,
        textColor: CitusPalette.onCitrus,
        label: Text(
          unread > 999 ? '999+' : '$unread',
          semanticsLabel: '$unread unread',
        ),
        child: Icon(icon),
      );
      return NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (i) => _select(PhoneTab.values[i]),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        destinations: [
          NavigationDestination(
            icon: inbox(AppIcons.inbox),
            selectedIcon: inbox(AppIcons.inboxOn),
            label: 'Inbox',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.pins),
            selectedIcon: Icon(AppIcons.pinOn),
            label: 'Pins',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.found),
            selectedIcon: Icon(AppIcons.foundOn),
            label: 'Found',
            tooltip: 'Found in your mail',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.folders),
            selectedIcon: Icon(AppIcons.foldersOn),
            label: 'Folders',
          ),
        ],
      );
    },
  );
}

/// The app's scroll behaviour, except that the list can be pulled down
/// at its top even when it is short (to reach search).
final class _PullBehavior extends ScrollBehavior {
  const _PullBehavior(this.parent);

  final ScrollBehavior parent;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    final physics = parent.getScrollPhysics(context);
    final scrollable = context.widget;
    return scrollable is Scrollable &&
            axisDirectionToAxis(scrollable.axisDirection) == Axis.vertical
        ? AlwaysScrollableScrollPhysics(parent: physics)
        : physics;
  }

  @override
  Set<PointerDeviceKind> get dragDevices => parent.dragDevices;

  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      parent.getMultitouchDragStrategy(context);

  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers =>
      parent.pointerAxisModifiers;

  @override
  TargetPlatform getPlatform(BuildContext context) =>
      parent.getPlatform(context);

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => parent.buildScrollbar(context, child, details);

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => parent.buildOverscrollIndicator(context, child, details);

  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      parent.velocityTrackerBuilder(context);

  @override
  bool shouldNotify(_PullBehavior oldDelegate) =>
      parent.shouldNotify(oldDelegate.parent);
}

/// New message, above the navigation bar: citrus, like the button it
/// replaces.
final class _ComposeButton extends StatelessWidget {
  const _ComposeButton(this.onPressed);

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => PressScale(
    child: FloatingActionButton(
      tooltip: 'New message (C)',
      // No flight between pages (it also goes while one leaves).
      heroTag: null,
      backgroundColor: CitusPalette.citrus,
      foregroundColor: CitusPalette.onCitrus,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CitusmailTheme.radiusCard),
      ),
      onPressed: onPressed,
      child: const Icon(AppIcons.compose),
    ),
  );
}

/// A bar at the bottom in the navigation bar's place (the open message's
/// actions, those for the selected messages), lifted above the keyboard.
final class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(top: false, left: false, child: child),
    ),
  );
}

/// The phone's Found tab: the pages the app puts together from your mail
/// ("Found in your mail" in the sidebar), each said in a sentence.
final class FoundHub extends StatelessWidget {
  const FoundHub({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: ListColors.of(context).background,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Semantics(
              header: true,
              child: Text(
                FeatureGroup.found.title,
                style: theme.textTheme.headlineSmall,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              'Put together from your emails, on this device.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
          for (final f in Features.all)
            if (f.group == FeatureGroup.found)
              ListTile(
                key: ValueKey('found-${f.id}'),
                minVerticalPadding: 10,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(CitusmailTheme.radius),
                  ),
                  child: Icon(f.icon, color: colors.primary),
                ),
                title: Text(f.title),
                subtitle: Text(f.sentence),
                trailing: Icon(
                  AppIcons.chevron,
                  color: colors.onSurfaceVariant,
                ),
                onTap: () => f.open(context, controller),
              ),
        ],
      ),
    );
  }
}
