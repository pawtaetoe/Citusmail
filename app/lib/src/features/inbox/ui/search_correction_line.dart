// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import '../state/mail_controller.dart';
import '../state/mail_location.dart';

/// Above search results found with typos corrected: what was searched
/// for instead, and a way to search for exactly what was typed.
final class SearchCorrectionLine extends StatelessWidget {
  const SearchCorrectionLine({super.key, required this.controller});

  final MailController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.list,
    builder: (context, _) {
      final corrected = controller.list.searchCorrection;
      final location = controller.list.location;
      if (corrected == null || location is! SearchLocation) {
        return const SizedBox.shrink();
      }
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              'Showing results for "$corrected"',
              style: theme.textTheme.bodyMedium,
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => controller.searchExactly(location.text),
              child: Text('Search for "${location.text}" instead'),
            ),
          ],
        ),
      );
    },
  );
}
