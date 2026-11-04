// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:mail_protocol/mail_protocol.dart';

import 'message_view.dart';
import 'safe_file_name.dart';

/// What kind of file an attachment is, for its icon and the filters of
/// the attachments page.
enum FileKind {
  pdf,
  image,
  document,
  spreadsheet,
  archive,
  calendar,
  other;

  /// The kind of a file called [fileName] with the type [mimeType]. The
  /// extension wins: senders often say `application/octet-stream`.
  static FileKind of(String fileName, String mimeType) {
    final dot = fileName.lastIndexOf('.');
    final extension = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    if (_byExtension[extension] case final kind?) return kind;
    final type = mimeType.toLowerCase();
    if (_byType[type] case final kind?) return kind;
    if (type.startsWith('image/')) return FileKind.image;
    if (type.contains('spreadsheet') || type.contains('excel')) {
      return FileKind.spreadsheet;
    }
    if (type.contains('wordprocessing') ||
        type.contains('presentation') ||
        type.contains('powerpoint') ||
        type.contains('msword') ||
        type.contains('opendocument.text')) {
      return FileKind.document;
    }
    return FileKind.other;
  }

  static final Map<String, FileKind> _byExtension = {
    'pdf': FileKind.pdf,
    for (final e in [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'heif',
      'bmp',
      'tif',
      'tiff',
    ])
      e: FileKind.image,
    for (final e in [
      'doc',
      'docx',
      'docm',
      'odt',
      'rtf',
      'txt',
      'md',
      'pages',
      'ppt',
      'pptx',
      'pptm',
      'odp',
      'key',
      'epub',
    ])
      e: FileKind.document,
    for (final e in ['xls', 'xlsx', 'xlsm', 'xlsb', 'ods', 'csv', 'tsv'])
      e: FileKind.spreadsheet,
    'numbers': FileKind.spreadsheet,
    for (final e in ['zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz'])
      e: FileKind.archive,
    for (final e in ['ics', 'ical', 'ifb', 'vcs']) e: FileKind.calendar,
  };

  static const _byType = {
    'application/pdf': FileKind.pdf,
    'application/rtf': FileKind.document,
    'text/plain': FileKind.document,
    'text/csv': FileKind.spreadsheet,
    'application/zip': FileKind.archive,
    'application/x-zip-compressed': FileKind.archive,
    'application/gzip': FileKind.archive,
    'application/x-7z-compressed': FileKind.archive,
    'application/x-rar-compressed': FileKind.archive,
    'application/vnd.rar': FileKind.archive,
    'text/calendar': FileKind.calendar,
    'application/ics': FileKind.calendar,
  };
}

/// One file attached to a message, as far as it is known without its
/// content: from the server's BODYSTRUCTURE at sync time, or from the
/// downloaded message. The name is already made safe by [SafeFileName].
final class FilePart {
  const FilePart({
    required this.name,
    required this.mimeType,
    required this.size,
    this.inline = false,
    this.hasContentId = false,
  });

  /// From a BODYSTRUCTURE node.
  factory FilePart.fromImap(ImapBodyPart part) => FilePart(
    name: SafeFileName.from(part.filename),
    mimeType: part.contentType.mimeType,
    size: part.encoding?.toLowerCase() == 'base64'
        ? part.size * 3 ~/ 4
        : part.size,
    inline: part.disposition?.isInline ?? false,
    hasContentId: part.contentId != null,
  );

  /// From an attachment of a downloaded message.
  factory FilePart.fromView(AttachmentView attachment) => FilePart(
    name: attachment.fileName,
    mimeType: attachment.mimeType,
    size: attachment.approximateSize,
    inline: attachment.inline,
    hasContentId: attachment.contentId != null,
  );

  /// The files of a message, from its BODYSTRUCTURE: the parts the reader
  /// lists as attachments.
  static List<FilePart> listFromImap(ImapBodyPart root) => [
    for (final part in root.allParts)
      if (part.isAttachment) FilePart.fromImap(part),
  ];

  /// The files of a downloaded message, as the reader lists them.
  static List<FilePart> listFromView(MessageView view) => [
    for (final a in view.attachments) FilePart.fromView(a),
  ];

  /// The stored header (in the message's kept headers) that holds the
  /// files, one value per file. Only the app writes it: the header fields
  /// asked from servers never include it.
  static const storedHeader = 'x-citusmail-file';

  /// Images below this are spacers, icons and logos.
  static const tinyImage = 2 * 1024;

  /// Images shown inside the text (inline, or with a Content-ID for a
  /// `cid:` link) below this are logos and signature pictures.
  static const layoutImage = 100 * 1024;

  final String name;
  final String mimeType;

  /// Decoded size in bytes (approximate).
  final int size;

  /// Content-Disposition: inline (shown in the text).
  final bool inline;

  /// Has a Content-ID, so the text can show it with a `cid:` link.
  final bool hasContentId;

  FileKind get kind => FileKind.of(name, mimeType);

  /// Whether this is only part of the message's look (a logo, a
  /// signature picture, a spacer) rather than a file someone sent.
  bool get isLayoutImage {
    if (kind != FileKind.image) return false;
    if (size < tinyImage) return true;
    return (inline || hasContentId) && size < layoutImage;
  }

  /// For [storedHeader].
  String encode() => jsonEncode({
    'name': name,
    'type': mimeType,
    'size': size,
    if (inline) 'inline': true,
    if (hasContentId) 'cid': true,
  });

  /// From a [storedHeader] value; null if it is not one.
  static FilePart? decode(String value) {
    try {
      final map = jsonDecode(value);
      if (map is! Map<String, Object?>) return null;
      final name = map['name'];
      final type = map['type'];
      final size = map['size'];
      if (name is! String || type is! String || size is! int) return null;
      return FilePart(
        name: SafeFileName.from(name),
        mimeType: type,
        size: size < 0 ? 0 : size,
        inline: map['inline'] == true,
        hasContentId: map['cid'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FilePart &&
      other.name == name &&
      other.mimeType == mimeType &&
      other.size == size &&
      other.inline == inline &&
      other.hasContentId == hasContentId;

  @override
  int get hashCode => Object.hash(name, mimeType, size, inline, hasContentId);

  @override
  String toString() => 'FilePart($name, $mimeType, $size)';
}

/// The chips of the attachments page.
enum FileFilter {
  all,
  pdfs,
  images,
  documents,
  spreadsheets,
  other;

  bool includes(FileKind kind) => switch (this) {
    all => true,
    pdfs => kind == FileKind.pdf,
    images => kind == FileKind.image,
    documents => kind == FileKind.document,
    spreadsheets => kind == FileKind.spreadsheet,
    other => const {
      FileKind.archive,
      FileKind.calendar,
      FileKind.other,
    }.contains(kind),
  };
}

/// Matching typed text against a file, its sender and the subject of its
/// message: every word must appear in one of them (ignoring case).
abstract final class FileSearch {
  /// The words of [text], lower case.
  static List<String> words(String text) => [
    for (final w in text.toLowerCase().split(RegExp(r'\s+')))
      if (w.isNotEmpty) w,
  ];

  static bool matches(
    List<String> words, {
    required String fileName,
    String? senderName,
    String? senderAddress,
    String? subject,
  }) {
    if (words.isEmpty) return true;
    final haystack = [
      fileName,
      ?senderName,
      ?senderAddress,
      ?subject,
    ].join('\n').toLowerCase();
    return words.every(haystack.contains);
  }
}
