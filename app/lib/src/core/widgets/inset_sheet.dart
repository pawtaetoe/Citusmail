// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// Shows what [builder] makes in a sheet from the bottom of the screen
/// (phones), clear of the system's own bars on every phone: its content
/// sits above Android's navigation (gesture bar or buttons) and, while
/// typing, above the keyboard; the sheet itself stays below the status
/// bar. The room comes from the screen's real insets, which differ from
/// phone to phone, never from a fixed size.
///
/// [maxHeightFactor] caps the content's height as a share of the
/// screen's (e.g. 0.85).
Future<T?> showInsetSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double? maxHeightFactor,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  // The top, left and right (the sheet's own SafeArea leaves the bottom
  // to its content: below).
  useSafeArea: true,
  builder: (context) {
    Widget content = SafeArea(top: false, child: builder(context));
    if (maxHeightFactor case final factor?) {
      content = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * factor,
        ),
        child: content,
      );
    }
    // The keyboard covers the navigation bar: while it is up, the
    // SafeArea's bottom is zero and this lifts the content instead.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: content,
    );
  },
);
