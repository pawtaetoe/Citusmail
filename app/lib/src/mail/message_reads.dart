// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

/// Reads a batch of messages (each its downloaded body, or null, and its
/// preview) into what a page needs. Runs off the UI thread, so it must be
/// a top-level or static function.
typedef MessageReader<T> = List<T> Function(List<(Uint8List?, String?)>);

/// What one page reads of each message (its text, the booking data in
/// it), kept per message so the pages and reading ahead
/// ([AutoReader]) look only at mail that is new or whose body arrived
/// since the last time.
///
/// Only the messages not read yet go to a worker isolate (in batches),
/// and only their bodies are loaded; with nothing new no isolate is
/// started at all. Results live in memory only, per store, and at most
/// [maxChars] of text per kind of read (the least recently used go
/// first).
final class MessageReads<T> {
  MessageReads(this._read, {required this.size, this.maxChars = 6000000});

  final MessageReader<T> _read;

  /// How much text one result holds (what [maxChars] counts).
  final int Function(T) size;

  /// Text kept at most, over all messages.
  final int maxChars;

  /// Messages sent to a worker per isolate.
  static const batch = 400;

  /// Messages read so far by every [MessageReads] (for tests).
  @visibleForTesting
  static int readCount = 0;

  /// Per store: what is known of each message.
  final _byStore = Expando<_Reads<T>>();

  /// Whether each message's body was on the device the last time any page
  /// read it, per store.
  static final _bodies = Expando<Map<int, bool>>();

  /// What [messages] say, in order: cached results for those read
  /// before (and whose body has not arrived since), a fresh read for the
  /// others.
  Future<List<T>> read(MailStore store, List<StoredMessage> messages) async {
    final reads = _byStore[store] ??= _Reads<T>();
    final bodies = _bodies[store] ??= {};
    final results = List<T?>.filled(messages.length, null);
    final missing = <int>[];
    final inputs = <(Uint8List?, String?)>[];
    for (final (i, m) in messages.indexed) {
      final known = reads.take(m);
      if (known != null && known.fromBody) {
        bodies[m.id] = true;
        results[i] = known.value;
        continue;
      }
      // Not read, or read from the preview: has the body come since?
      final raw = store.messages.body(m.id);
      bodies[m.id] = raw != null;
      if (known != null && raw == null && known.snippet == m.snippet) {
        results[i] = known.value;
        continue;
      }
      missing.add(i);
      inputs.add((raw, m.snippet));
    }
    for (var start = 0; start < inputs.length; start += batch) {
      final end = start + batch < inputs.length ? start + batch : inputs.length;
      final read = await compute(_read, inputs.sublist(start, end));
      readCount += read.length;
      for (var j = 0; j < read.length; j++) {
        final i = missing[start + j];
        final m = messages[i];
        final (raw, snippet) = inputs[start + j];
        results[i] = read[j];
        reads.put(
          m,
          _Read(
            mailboxId: m.mailboxId,
            uid: m.uid,
            fromBody: raw != null,
            snippet: snippet,
            value: read[j],
            size: size(read[j]),
          ),
          maxChars,
        );
      }
    }
    return [for (final r in results) r as T];
  }

  /// Whether [messageId]'s body is on the device: what the last read
  /// found (bodies are never removed while the message is stored), else
  /// a look in the store.
  static bool downloaded(MailStore store, int messageId) {
    final bodies = _bodies[store] ??= {};
    if (bodies[messageId] == true) return true;
    final has = store.messages.body(messageId) != null;
    bodies[messageId] = has;
    return has;
  }
}

final class _Read<T> {
  const _Read({
    required this.mailboxId,
    required this.uid,
    required this.fromBody,
    required this.snippet,
    required this.value,
    required this.size,
  });

  /// Which message it was (an id can be used again once a message is
  /// gone).
  final int mailboxId;
  final int uid;
  final bool fromBody;
  final String? snippet;
  final T value;
  final int size;
}

/// Results by message id, the least recently used first.
final class _Reads<T> {
  // Map literals keep insertion order.
  final _entries = <int, _Read<T>>{};
  int _chars = 0;

  _Read<T>? take(StoredMessage m) {
    final entry = _entries.remove(m.id);
    if (entry == null) return null;
    if (entry.mailboxId != m.mailboxId || entry.uid != m.uid) {
      _chars -= entry.size;
      return null;
    }
    _entries[m.id] = entry;
    return entry;
  }

  void put(StoredMessage m, _Read<T> entry, int maxChars) {
    if (_entries.remove(m.id) case final old?) _chars -= old.size;
    _entries[m.id] = entry;
    _chars += entry.size;
    while (_chars > maxChars && _entries.length > 1) {
      final oldest = _entries.keys.first;
      _chars -= _entries.remove(oldest)!.size;
    }
  }
}

/// The text the Subscriptions and Online accounts pages read, kept per
/// message ([plainTexts]).
final plainTextReads = MessageReads<String>(plainTexts, size: (t) => t.length);

/// Each message's text: the downloaded body when there is one (capped),
/// else its preview.
List<String> plainTexts(List<(Uint8List?, String?)> messages) => [
  for (final (raw, snippet) in messages)
    if (raw != null)
      () {
        final text = MessageView.parse(raw).body.plainText;
        return text.length > 20000 ? text.substring(0, 20000) : text;
      }()
    else
      snippet ?? '',
];
