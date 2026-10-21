// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

/// Turns an attachment name chosen by the sender into one that is safe to
/// show and to save on Linux, Windows and Android.
///
/// The sender controls the name, so it may try to escape the download
/// folder (`../../.bashrc`), hide its real extension with right-to-left
/// override characters (`invoice<U+202E>fdp.exe` shows as `invoiceexe.pdf`),
/// use names Windows reserves (`CON`, `NUL`...), or be absurdly long.
abstract final class SafeFileName {
  /// UTF-8 bytes; file systems allow 255.
  static const maxBytes = 200;

  static String from(String? original, {String fallback = 'attachment'}) {
    var name = original ?? '';
    // Only the last path component.
    final slash = name.lastIndexOf(RegExp(r'[/\\]'));
    if (slash >= 0) name = name.substring(slash + 1);

    final cleaned = StringBuffer();
    for (final rune in name.runes) {
      if (rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        cleaned.write(' ');
        continue;
      }
      if (_isInvisibleOrControl(rune)) continue;
      cleaned.writeCharCode(_reserved.contains(rune) ? 0x5F : rune); // _
    }
    name = cleaned
        .toString()
        .replaceAll(RegExp(r'\s+'), ' ')
        // No hidden files, no trailing dots or spaces (Windows drops them).
        .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');

    if (name.isEmpty) name = fallback;
    final base = name.split('.').first.trim().toUpperCase();
    if (_windowsDevices.hasMatch(base)) name = '_$name';
    return _shorten(name);
  }

  /// Unicode characters that change how text is displayed without being
  /// visible, plus control characters.
  static bool _isInvisibleOrControl(int rune) =>
      rune < 0x20 ||
      (rune >= 0x7F && rune <= 0x9F) ||
      rune == 0x00AD || // soft hyphen
      rune == 0x061C || // Arabic letter mark
      (rune >= 0x200B && rune <= 0x200F) || // zero width, LRM, RLM
      (rune >= 0x202A && rune <= 0x202E) || // embeddings and overrides
      (rune >= 0x2066 && rune <= 0x2069) || // isolates
      rune == 0xFEFF;

  /// Not allowed in Windows file names.
  static const _reserved = {
    0x3C,
    0x3E,
    0x3A,
    0x22,
    0x7C,
    0x3F,
    0x2A,
  }; // <>:"|?*

  static final _windowsDevices = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[0-9\u00B9\u00B2\u00B3]|LPT[0-9\u00B9\u00B2\u00B3])$',
  );

  /// Cuts the name to [maxBytes] of UTF-8, keeping a short extension.
  static String _shorten(String name) {
    if (utf8.encode(name).length <= maxBytes) return name;
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 && name.length - dot <= 16
        ? name.substring(dot)
        : '';
    final stem = extension.isEmpty ? name : name.substring(0, dot);
    final budget = maxBytes - utf8.encode(extension).length;
    final kept = StringBuffer();
    var used = 0;
    for (final rune in stem.runes) {
      final size = utf8.encode(String.fromCharCode(rune)).length;
      if (used + size > budget) break;
      kept.writeCharCode(rune);
      used += size;
    }
    return '${kept.toString().trimRight()}$extension';
  }
}
