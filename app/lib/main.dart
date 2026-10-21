// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

/// Placeholder product name. The final name is still open, so it lives in one
/// place to make renaming easy.
const String appName = 'Fmail';

void main() {
  runApp(const MailApp());
}

class MailApp extends StatelessWidget {
  const MailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const Scaffold(
        body: Center(child: Text('$appName is under construction')),
      ),
    );
  }
}
