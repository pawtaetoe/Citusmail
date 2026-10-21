// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:mail_view/mail_view.dart';
import 'package:path_provider/path_provider.dart';

/// Saves attachments into the Downloads folder. Files are never opened
/// automatically: an attachment can be malware.
abstract final class AttachmentSaver {
  /// Writes [attachment] and returns where. Never overwrites a file.
  static Future<File> save(AttachmentView attachment) async {
    final directory =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    await directory.create(recursive: true);
    final file = await _createNew(directory, attachment.fileName);
    try {
      await file.writeAsBytes(attachment.bytes(), flush: true);
    } on Object {
      await file.delete();
      rethrow;
    }
    return file;
  }

  /// Creates `report.pdf`, else `report (1).pdf`, `report (2).pdf`...
  /// Creation is exclusive, so an existing file is never overwritten.
  static Future<File> _createNew(Directory directory, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var i = 0; i < 1000; i++) {
      final candidate = i == 0 ? name : '$stem ($i)$extension';
      final file = File('${directory.path}${Platform.pathSeparator}$candidate');
      // The name is sanitised, but check anyway that it stays in the folder.
      if (file.parent.absolute.path != directory.absolute.path) {
        throw const FileSystemException('unsafe attachment name');
      }
      try {
        await file.create(exclusive: true);
        return file;
      } on FileSystemException {
        if (file.existsSync()) continue; // taken: try the next name
        rethrow;
      }
    }
    throw FileSystemException('too many files named $name', directory.path);
  }
}
