// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mail_view/mail_view.dart';
import 'package:path_provider/path_provider.dart';

/// Where a file was saved: [path] is what to tell the user.
final class SavedFile {
  const SavedFile(this.path);

  final String path;
}

/// Saves attachments (and whole messages, as .eml) into the Downloads
/// folder: on Android the public Download/Citusmail folder the Files app
/// shows. Files are never opened automatically: an attachment can be
/// malware.
abstract final class AttachmentSaver {
  static const _android = MethodChannel('citusmail/files');

  /// Whether this is Android (tests set it).
  @visibleForTesting
  static bool Function() isAndroid = () => !kIsWeb && Platform.isAndroid;

  /// The Downloads folder the platform gives (tests set it).
  @visibleForTesting
  static Future<Directory> Function() downloads = () async =>
      await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();

  /// The folder on Android, as the Files app names it.
  static const androidFolder = 'Download/Citusmail';

  /// Writes [attachment] and returns where. Never overwrites a file.
  static Future<SavedFile> save(AttachmentView attachment) =>
      saveBytes(attachment.fileName, attachment.bytes());

  /// Writes [bytes] as [fileName] (already a safe name, see
  /// `SafeFileName`) into Downloads and returns where. Never overwrites a
  /// file.
  static Future<SavedFile> saveBytes(String fileName, List<int> bytes) async {
    if (isAndroid()) {
      // Android 10+: through MediaStore into the public folder. Null on
      // older Android, which keeps the app's own folder below.
      final name = await _android.invokeMethod<String>('saveToDownloads', {
        'name': fileName,
        'bytes': Uint8List.fromList(bytes),
        'mime': _mimeOf(fileName),
      });
      if (name != null) return SavedFile('$androidFolder/$name');
    }
    return SavedFile((await _saveFile(fileName, bytes)).path);
  }

  /// The file's type from its name, for the Files app; anything unknown
  /// is plain bytes.
  static String _mimeOf(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'txt' => 'text/plain',
      'csv' => 'text/csv',
      'ics' => 'text/calendar',
      'eml' => 'message/rfc822',
      'zip' => 'application/zip',
      'doc' => 'application/msword',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt' => 'application/vnd.ms-powerpoint',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      _ => 'application/octet-stream',
    };
  }

  /// Writes into the Downloads folder the platform gives (the user's
  /// Downloads on a computer; the app's own folder on older Android).
  static Future<File> _saveFile(String fileName, List<int> bytes) async {
    final directory = await downloads();
    await directory.create(recursive: true);
    final file = await _createNew(directory, fileName);
    try {
      await file.writeAsBytes(bytes, flush: true);
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
