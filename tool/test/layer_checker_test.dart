// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:repo_tools/repo_tools.dart';
import 'package:test/test.dart';

void main() {
  const checker = LayerChecker();
  List<String> reasons(String path, String content) => [
    for (final v in checker.check(path, content)) v.reason,
  ];

  test('core depends on no feature, service or app code', () {
    expect(
      reasons(
        'app/lib/src/core/widgets/x.dart',
        "import '../../features/inbox/ui/sidebar.dart';",
      ),
      [contains('core/ is shared')],
    );
    expect(
      reasons(
        'app/lib/src/core/theme/x.dart',
        "import 'package:citusmail/src/services/app_services.dart';",
      ),
      [contains('core/ is shared')],
    );
    expect(
      reasons('app/lib/src/core/theme/x.dart', "import 'app_icons.dart';"),
      isEmpty,
    );
  });

  test('state and services hold no widgets', () {
    expect(
      reasons(
        'app/lib/src/features/inbox/state/x.dart',
        "import '../ui/message_tile.dart';",
      ),
      [contains('no widget code')],
    );
    expect(
      reasons(
        'app/lib/src/services/x.dart',
        "import '../core/widgets/avatar.dart';",
      ),
      [contains('no widget code')],
    );
    expect(
      reasons(
        'app/lib/src/features/found/state/x.dart',
        "import 'package:flutter/material.dart';",
      ),
      [contains('no widgets')],
    );
    expect(
      reasons(
        'app/lib/src/features/found/state/x.dart',
        "import 'package:flutter/foundation.dart';\n"
            "import '../../../core/theme/motion.dart';\n"
            "import '../../inbox/state/mail_controller.dart';",
      ),
      isEmpty,
    );
  });

  test('a feature\'s widgets may use anything; other code is not checked', () {
    expect(
      reasons(
        'app/lib/src/features/inbox/ui/x.dart',
        "import 'package:flutter/material.dart';\n"
            "import '../../reader/ui/reader_pane.dart';",
      ),
      isEmpty,
    );
    expect(
      reasons(
        'packages/mail_store/lib/x.dart',
        "import 'package:flutter/material.dart';",
      ),
      isEmpty,
    );
  });
}
