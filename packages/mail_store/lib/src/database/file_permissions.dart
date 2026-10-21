// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Makes the database files readable by the user only. The content is
/// encrypted anyway, but other accounts on the machine should not even see
/// its size or copy it for offline attacks.
///
/// On Linux, macOS and Android this sets mode 700 on the folder and 600 on
/// the files (SQLite gives its `-wal` and `-shm` files the database file's
/// mode). On Windows, files under the user's profile are already private.
///
/// Best effort: a file system without Unix permissions (rare for app data)
/// must not stop the app from opening its encrypted data.
abstract final class FilePermissions {
  static void restrict(String databasePath) {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isAndroid)) return;
    if (databasePath == ':memory:' || databasePath.isEmpty) return;
    _chmod(File(databasePath).parent.path, 448); // 0700
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final path = '$databasePath$suffix';
      if (File(path).existsSync()) _chmod(path, 384); // 0600
    }
  }

  static final _chmodNative = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');

  static void _chmod(String path, int mode) {
    final native = path.toNativeUtf8();
    try {
      _chmodNative(native, mode); // non-zero (failure) is tolerated, see above
    } finally {
      malloc.free(native);
    }
  }
}
