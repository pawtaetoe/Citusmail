// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import '../services/app_services.dart';

/// One file in the attachments list.
final class LibraryFile {
  const LibraryFile({
    required this.message,
    required this.file,
    required this.index,
    required this.downloaded,
  });

  final StoredMessage message;
  final FilePart file;

  /// Which of the message's files with this name it is (usually 0).
  final int index;

  /// Whether the message is on the device, so the file can be saved (and
  /// an image shown) without asking the server.
  final bool downloaded;

  FileKind get kind => file.kind;

  /// Stays the same while the message does.
  String get key => '${message.id}/$index/${file.name}';

  /// For "don't list this file": survives the message moving folders.
  String get hideKey =>
      '${message.messageId ?? 'id:${message.id}'}/${file.name}';
}

/// The Attachments page's data: files people sent, newest first, across
/// every account and folder but Trash, Junk and Drafts. Found on the
/// device: names, types and sizes are kept from what the server says at
/// sync (BODYSTRUCTURE) or read from downloaded messages, page by page,
/// off the UI thread. Nothing is downloaded unless the user asks.
final class AttachmentsModel extends ChangeNotifier {
  AttachmentsModel(this._services);

  final AppServices _services;

  MailStore get _store => _services.store;

  static const _hiddenKey = 'attachments.hidden';
  static const _maxHidden = 1000;

  /// Messages read from the store at once.
  static const _page = 200;

  /// Files listed before more are read (scrolling reads more).
  static const _batch = 60;

  /// Downloaded messages parsed at once, off the UI thread.
  static const _parseChunk = 20;

  /// Image previews kept in memory.
  static const _maxPreviews = 48;

  /// Bigger images get no preview.
  static const _maxPreviewBytes = 12 * 1024 * 1024;

  static const _previewTypes = {
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/bmp',
  };

  FileFilter _filter = FileFilter.all;
  bool _peopleOnly = false;
  String _search = '';

  FileFilter get filter => _filter;
  bool get peopleOnly => _peopleOnly;
  String get search => _search;

  bool loading = true;
  bool loadingMore = false;
  List<LibraryFile> files = const [];

  /// Messages with files this device has not listed yet (synced before
  /// file names were kept, and not downloaded).
  List<int> unknown = const [];

  /// While looking those up: how many are done, of how many.
  ({int done, int total})? lookingUp;

  /// The last lookup could not reach a server.
  bool lookupFailed = false;

  /// Files the user said not to list.
  Set<String> hidden = const {};

  StoredMessage? _cursor;
  bool _exhausted = false;
  int _generation = 0;
  bool _disposed = false;
  bool _stop = false;
  final _previews = <String, Uint8List?>{};

  /// Whether every matching file is listed.
  bool get complete => _exhausted;

  set filter(FileFilter value) {
    if (value == _filter) return;
    _filter = value;
    unawaited(load());
  }

  set peopleOnly(bool value) {
    if (value == _peopleOnly) return;
    _peopleOnly = value;
    unawaited(load());
  }

  set search(String value) {
    if (value.trim() == _search.trim()) return;
    _search = value;
    unawaited(load());
  }

  /// Lists from the start (after a filter or the search changed).
  Future<void> load() async {
    final generation = ++_generation;
    _cursor = null;
    _exhausted = false;
    files = const [];
    loading = true;
    loadingMore = false;
    hidden = {
      ...?_store.settings
          .read(_hiddenKey)
          ?.split('\n')
          .where((s) => s.isNotEmpty),
    };
    unknown = [
      for (final m in _store.messages.withUnknownFiles(
        header: FilePart.storedHeader,
      ))
        m.id,
    ];
    _notify();
    await _fill(generation, _batch);
    if (generation != _generation) return;
    loading = false;
    _notify();
  }

  /// Lists more files (the user scrolled near the end).
  Future<void> loadMore() async {
    if (loading || loadingMore || _exhausted) return;
    final generation = _generation;
    loadingMore = true;
    _notify();
    await _fill(generation, files.length + _batch);
    if (generation != _generation) return;
    loadingMore = false;
    _notify();
  }

  /// Reads pages of messages until [want] files are listed or there are
  /// no more.
  Future<void> _fill(int generation, int want) async {
    final words = FileSearch.words(_search);
    final found = <LibraryFile>[];
    while (!_exhausted && files.length + found.length < want) {
      final rows = _store.messages.withAttachments(
        header: FilePart.storedHeader,
        peopleOnly: _peopleOnly,
        words: words,
        before: _cursor,
        limit: _page,
      );
      if (rows.length < _page) _exhausted = true;
      if (rows.isEmpty) break;
      _cursor = rows.last.message;
      final parsed = await _parse([
        for (final r in rows)
          if (r.files.isEmpty && r.downloaded) r.message.id,
      ]);
      if (generation != _generation || _disposed) return;
      for (final r in rows) {
        final parts = r.files.isNotEmpty
            ? r.files.map(FilePart.decode).nonNulls.toList()
            : parsed[r.message.id] ?? const <FilePart>[];
        final seen = <String, int>{};
        for (final part in parts) {
          final index = seen[part.name] = (seen[part.name] ?? -1) + 1;
          final file = LibraryFile(
            message: r.message,
            file: part,
            index: index,
            downloaded: r.downloaded,
          );
          if (_lists(file, words)) found.add(file);
        }
      }
    }
    if (generation != _generation || _disposed) return;
    files = [...files, ...found];
  }

  bool _lists(LibraryFile f, List<String> words) =>
      !f.file.isLayoutImage &&
      _filter.includes(f.kind) &&
      !hidden.contains(f.hideKey) &&
      FileSearch.matches(
        words,
        fileName: f.file.name,
        senderName: f.message.from?.displayName,
        senderAddress: f.message.from?.address,
        subject: f.message.subject,
      );

  /// The files of downloaded messages that were never listed, read off
  /// the UI thread a few at a time and kept, so it happens once.
  Future<Map<int, List<FilePart>>> _parse(List<int> ids) async {
    final result = <int, List<FilePart>>{};
    for (var i = 0; i < ids.length; i += _parseChunk) {
      final chunk = ids.sublist(i, (i + _parseChunk).clamp(0, ids.length));
      final bodies = [for (final id in chunk) _store.messages.body(id)];
      final encoded = await compute(_filesOf, bodies);
      if (_disposed) return result;
      for (final (j, id) in chunk.indexed) {
        if (encoded[j].isEmpty) continue;
        _store.messages.setHeader(id, FilePart.storedHeader, encoded[j]);
        result[id] = encoded[j].map(FilePart.decode).nonNulls.toList();
      }
    }
    return result;
  }

  /// Asks the mail servers which files the [unknown] messages have: only
  /// their structure, nothing is downloaded and they stay unread.
  Future<void> lookUp() async {
    if (lookingUp != null || unknown.isEmpty) return;
    final ids = unknown;
    _stop = false;
    lookupFailed = false;
    var done = 0;
    lookingUp = (done: 0, total: ids.length);
    _notify();
    for (var i = 0; i < ids.length && !_stop; i += 100) {
      final chunk = ids.sublist(i, (i + 100).clamp(0, ids.length));
      try {
        await _services.worker.lookUpFiles(chunk);
      } on Object {
        lookupFailed = true;
        break;
      }
      done += chunk.length;
      lookingUp = (done: done, total: ids.length);
      _notify();
    }
    lookingUp = null;
    if (_disposed) return;
    await load();
  }

  void stopLookingUp() => _stop = true;

  /// A preview of an image that is already on the device; null when
  /// there is none (not downloaded, not a common image type, too big).
  /// Never asks a server.
  Future<Uint8List?> preview(LibraryFile f) async {
    if (!f.downloaded ||
        !_previewTypes.contains(f.file.mimeType.toLowerCase()) ||
        f.file.size > _maxPreviewBytes) {
      return null;
    }
    if (_previews.containsKey(f.key)) {
      final bytes = _previews.remove(f.key);
      return _previews[f.key] = bytes; // most recently used last
    }
    final raw = _store.messages.body(f.message.id);
    if (raw == null) return null;
    final bytes = await compute(_bytesOf, (raw, f.file.name, f.index));
    _previews[f.key] = bytes;
    while (_previews.length > _maxPreviews) {
      _previews.remove(_previews.keys.first);
    }
    return bytes;
  }

  /// The content of [f], downloading its message first if needed (it
  /// stays unread). Throws when the message cannot be downloaded; null
  /// when the file is not in it.
  Future<Uint8List?> content(LibraryFile f) async {
    if (_store.messages.body(f.message.id) == null) {
      await _services.worker.loadBody(f.message.id);
    }
    final raw = _store.messages.body(f.message.id);
    if (raw == null) return null;
    return compute(_bytesOf, (raw, f.file.name, f.index));
  }

  /// "Don't list this file" (undoable).
  void hide(LibraryFile f) {
    final kept = {...hidden, f.hideKey}.toList();
    _setHidden(kept.skip((kept.length - _maxHidden).clamp(0, kept.length)));
  }

  void unhide(LibraryFile f) => _setHidden({...hidden}..remove(f.hideKey));

  void _setHidden(Iterable<String> keys) {
    _store.settings.write(_hiddenKey, keys.join('\n'));
    unawaited(load());
  }

  StoredMessage? message(int id) => _store.messages.byId(id);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop = true;
    super.dispose();
  }
}

/// The files of each downloaded message, in their stored form.
List<List<String>> _filesOf(List<Uint8List?> bodies) => [
  for (final raw in bodies)
    if (raw == null)
      const <String>[]
    else
      [
        for (final f in FilePart.listFromView(MessageView.parse(raw)))
          f.encode(),
      ],
];

/// The content of the [index]th file called [name] in a message.
Uint8List? _bytesOf((Uint8List, String, int) request) {
  final (raw, name, index) = request;
  final matching = [
    for (final a in MessageView.parse(raw).attachments)
      if (a.fileName == name) a,
  ];
  if (matching.isEmpty) return null;
  return matching[index.clamp(0, matching.length - 1)].bytes();
}
