// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:mail_view/mail_view.dart';
import 'package:mail_web/mail_web.dart';

/// Downloads images the user chose to load, through the hardened
/// [WebClient]: tracking addresses are refused (also after a redirect),
/// sizes are limited, and only real PNG, JPEG, GIF or WebP images of a
/// size safe to decode are returned. Kept in memory only, for this run of
/// the app.
final class RemoteImages {
  RemoteImages(
    this._web, {
    this.maxImageBytes = 5 * 1024 * 1024,
    this.maxCacheBytes = 64 * 1024 * 1024,
    this.maxParallel = 4,
  });

  final WebClient _web;
  final int maxImageBytes;
  final int maxCacheBytes;
  final int maxParallel;

  /// Loaded images (or null for ones that failed), most recent last.
  final _cache = <String, Uint8List?>{}; // keeps insertion order
  int _cachedBytes = 0;
  final _inFlight = <String, Future<Uint8List?>>{};
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  /// The image at [url], or null if it can't be shown (unreachable,
  /// refused, too large, not an image). Never throws.
  Future<Uint8List?> load(Uri url) {
    final key = url.toString();
    if (_cache.containsKey(key)) {
      final bytes = _cache.remove(key);
      _cache[key] = bytes; // most recently used
      return Future.value(bytes);
    }
    // The callback must not return the removed future: whenComplete would
    // wait for it, which is this very future.
    return _inFlight[key] ??= _fetch(url).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<Uint8List?> _fetch(Uri url) async {
    await _slot();
    Uint8List? result;
    try {
      final download = await _web.get(
        url,
        maxBytes: maxImageBytes,
        allow: (u) => !TrackingPixels.isTracker(u),
      );
      // The bytes decide, not the server's Content-Type.
      if (ImageHeader.read(download.bytes) != null) result = download.bytes;
    } on WebException {
      result = null;
    } finally {
      _release();
    }
    _remember(url.toString(), result);
    return result;
  }

  void _remember(String key, Uint8List? bytes) {
    _cache[key] = bytes;
    _cachedBytes += bytes?.length ?? 0;
    while (_cachedBytes > maxCacheBytes && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      _cachedBytes -= _cache.remove(oldest)?.length ?? 0;
    }
  }

  Future<void> _slot() async {
    if (_running < maxParallel) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future; // the slot is handed over by _release
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}
