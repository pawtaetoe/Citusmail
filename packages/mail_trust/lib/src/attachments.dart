// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'trust_report.dart';

/// Attachment names that can run code when opened.
abstract final class RiskyFiles {
  /// Programs and scripts: opening one runs it.
  static const programs = {
    'exe',
    'scr',
    'com',
    'pif',
    'bat',
    'cmd',
    'msi',
    'msp',
    'msix',
    'msixbundle',
    'appx',
    'appxbundle',
    'appref-ms',
    'application',
    'jar',
    'js',
    'jse',
    'vbs',
    'vbe',
    'wsf',
    'wsh',
    'wsc',
    'ps1',
    'psm1',
    'psd1',
    'hta',
    'cpl',
    'lnk',
    'reg',
    'dll',
    'sys',
    'scf',
    'url',
    'inf',
    'msc',
    'gadget',
    'chm',
    'xll',
    'iqy',
    'slk',
    'settingcontent-ms',
    'library-ms',
    'search-ms',
    'apk',
    'xapk',
    'apks',
    'aab',
    'app',
    'command',
    'pkg',
    'mpkg',
    'deb',
    'rpm',
    'sh',
    'bash',
    'run',
    'bin',
    'appimage',
    'desktop',
    'flatpakref',
    'snap',
    'py',
    'pyw',
    'pl',
    'rb',
    'php',
  };

  /// Disk images and shortcuts that hide what is inside from mail filters.
  static const containers = {'iso', 'img', 'vhd', 'vhdx', 'dmg'};

  /// Office files with macros, and HTML pages (fake sign-in forms that
  /// open in the browser, outside the protected reader).
  static const active = {
    'docm',
    'dotm',
    'xlsm',
    'xltm',
    'xlam',
    'xlsb',
    'pptm',
    'potm',
    'ppam',
    'ppsm',
    'sldm',
    'html',
    'htm',
    'xhtml',
    'shtml',
    'mht',
    'mhtml',
    'svg',
    'one',
  };

  /// Extensions that make people think a file is a harmless document.
  static const _documents = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
    'rtf',
    'odt',
    'ods',
    'csv',
    'jpg',
    'jpeg',
    'png',
    'gif',
    'mp3',
    'mp4',
    'mov',
    'zip',
  };

  /// The verdict on an attachment called [fileName] (already made safe by
  /// `SafeFileName`), or null if the name is not risky.
  static AttachmentVerdict? check(String fileName) {
    final parts = fileName.toLowerCase().split('.');
    if (parts.length < 2) return null;
    final ext = parts.last.trim();
    final before = parts.length > 2 ? parts[parts.length - 2].trim() : null;
    final runs = programs.contains(ext) || containers.contains(ext);
    if (runs && before != null && _documents.contains(before)) {
      return AttachmentVerdict(
        fileName,
        TrustLevel.danger,
        'Pretends to be a .$before file but is a .$ext program.',
      );
    }
    if (programs.contains(ext)) {
      return AttachmentVerdict(
        fileName,
        TrustLevel.danger,
        'A .$ext file is a program. Opening it can take over your device.',
      );
    }
    if (containers.contains(ext)) {
      return AttachmentVerdict(
        fileName,
        TrustLevel.caution,
        'A .$ext disk image can hide programs from safety checks.',
      );
    }
    if (active.contains(ext)) {
      final html = const {
        'html',
        'htm',
        'xhtml',
        'shtml',
        'mht',
        'mhtml',
        'svg',
      }.contains(ext);
      return AttachmentVerdict(
        fileName,
        TrustLevel.caution,
        html
            ? 'A web page opens in your browser, outside this app\'s protection. '
                  'Never sign in on a page from an attachment.'
            : 'This document can contain macros. Don\'t enable macros or editing.',
      );
    }
    return null;
  }
}
