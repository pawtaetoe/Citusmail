// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:repo_tools/repo_tools.dart';
import 'package:test/test.dart';

void main() {
  final checker = ImportChecker();

  test('network imports are refused in shipped code', () {
    final found = checker.check(
      'app/lib/x.dart',
      "import 'package:http/http.dart';\n"
          "import 'package:timezone/standalone.dart';\n"
          'import "package:webview_flutter/webview_flutter.dart";\n'
          'final c = HttpClient();\n',
    );
    expect(found.map((v) => v.line), [1, 2, 3, 4]);
  });

  test(
    'raw connections stay in mail_protocol, mail-named servers in mail_web',
    () {
      expect(
        checker
            .check(
              'app/lib/x.dart',
              'await SecureSocket.connect(h, 443);\n'
                  'await RawSocket.connect(h, 1);\n'
                  'await MailSocket.connect(e);\n'
                  'await RawDatagramSocket.bind(a, 0);\n',
            )
            .map((v) => v.line),
        [1, 2, 3, 4],
      );
      expect(
        checker.check(
          'packages/mail_protocol/lib/src/net/mail_socket.dart',
          'RawSocket.connect(a, b); MailSocket.connect(e);',
        ),
        isEmpty,
      );
      expect(
        checker.check('packages/mail_web/lib/a.dart', 'MailSocket.connect(e)'),
        isEmpty,
      );
      expect(
        checker.check('packages/mail_web/lib/a.dart', 'Socket.connect(h, 1)'),
        hasLength(1),
      );
      expect(
        checker.check(
          'packages/mail_setup/lib/a.dart',
          'RawDatagramSocket.bind(a, 0)',
        ),
        isEmpty,
      );
    },
  );

  test('allowed where reviewed, and comments are ignored', () {
    expect(
      checker.check('packages/mail_setup/lib/a.dart', 'HttpClient()'),
      isEmpty,
    );
    expect(
      checker.check('app/lib/a.dart', "// import 'package:http/http.dart';"),
      isEmpty,
    );
    expect(
      checker.check(
        'app/lib/a.dart',
        "import 'package:timezone/timezone.dart';",
      ),
      isEmpty,
    );
  });
}
