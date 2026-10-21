// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'imap_command.dart';
import 'sequence_set.dart';

/// What to fetch for each message. Builds the FETCH item list so callers
/// never write raw protocol syntax.
final class FetchItems {
  FetchItems({
    this.uid = true,
    this.flags = false,
    this.internalDate = false,
    this.size = false,
    this.envelope = false,
    this.bodyStructure = false,
    this.modSeq = false,
    this.header = false,
    this.fullMessage = false,
    this.preview = false,
    List<String> headerFields = const [],
    List<String> sections = const [],
  }) : sections = List.unmodifiable(sections),
       headerFields = List.unmodifiable(headerFields) {
    for (final section in sections) {
      if (!_section.hasMatch(section)) {
        throw ArgumentError.value(section, 'sections', 'invalid section');
      }
    }
    for (final field in headerFields) {
      if (!_fieldName.hasMatch(field)) {
        throw ArgumentError.value(field, 'headerFields', 'invalid header name');
      }
    }
  }

  /// What the message list needs: flags, dates, size, envelope, structure.
  factory FetchItems.summary({bool modSeq = false}) => FetchItems(
    flags: true,
    internalDate: true,
    size: true,
    envelope: true,
    bodyStructure: true,
    modSeq: modSeq,
  );

  /// Flags only (for resynchronising flag changes).
  factory FetchItems.flagsOnly({bool modSeq = false}) =>
      FetchItems(flags: true, modSeq: modSeq);

  final bool uid;
  final bool flags;
  final bool internalDate;
  final bool size;
  final bool envelope;
  final bool bodyStructure;
  final bool modSeq;

  /// The whole header section (BODY.PEEK[HEADER]).
  final bool header;

  /// The complete raw message (BODY.PEEK[]).
  final bool fullMessage;

  /// Specific parts by IMAP section number, e.g. `1.2`. Fetched with PEEK,
  /// so reading never marks a message as seen by itself.
  final List<String> sections;

  /// A short text preview (RFC 8970). Only when the server has PREVIEW.
  final bool preview;

  /// Only these header fields (BODY.PEEK[HEADER.FIELDS (...)]); read the
  /// result with [FetchedMessage.headerFields].
  final List<String> headerFields;

  static final _section = RegExp(r'^\d+(\.\d+)*(\.(HEADER|TEXT|MIME))?$');
  static final _fieldName = RegExp(r'^[!-9;-~]+$');

  /// e.g. `(UID FLAGS BODY.PEEK[1.2])`.
  String toSyntax() {
    final items = [
      if (uid) 'UID',
      if (flags) 'FLAGS',
      if (internalDate) 'INTERNALDATE',
      if (size) 'RFC822.SIZE',
      if (envelope) 'ENVELOPE',
      if (bodyStructure) 'BODYSTRUCTURE',
      if (modSeq) 'MODSEQ',
      if (header) 'BODY.PEEK[HEADER]',
      if (fullMessage) 'BODY.PEEK[]',
      if (preview) 'PREVIEW',
      if (headerFields.isNotEmpty)
        'BODY.PEEK[HEADER.FIELDS (${headerFields.join(' ')})]',
      for (final s in sections) 'BODY.PEEK[$s]',
    ];
    if (items.isEmpty) throw StateError('nothing to fetch');
    return '(${items.join(' ')})';
  }
}

/// Search criteria (RFC 9051 6.4.4), combined with AND. Only what the app
/// needs; every value is encoded safely by [ImapCommand].
final class SearchCriteria {
  SearchCriteria._(this._apply);

  final void Function(ImapCommand command) _apply;

  static SearchCriteria all() => SearchCriteria._((c) => c.atom('ALL'));

  static SearchCriteria uids(SequenceSet set) => SearchCriteria._(
    (c) => c
      ..atom('UID')
      ..sequenceSet(set),
  );

  /// Messages whose mod-sequence is at least [modSeq] (CONDSTORE).
  static SearchCriteria modSeqAtLeast(int modSeq) => SearchCriteria._(
    (c) => c
      ..atom('MODSEQ')
      ..number(modSeq),
  );

  /// Internal date on or after [date] (date only, as IMAP compares days).
  static SearchCriteria since(DateTime date) => SearchCriteria._(
    (c) => c
      ..atom('SINCE')
      ..atom(_searchDate(date)),
  );

  static SearchCriteria unseen() => SearchCriteria._((c) => c.atom('UNSEEN'));

  /// Messages with the `\Draft` flag.
  static SearchCriteria draft() => SearchCriteria._((c) => c.atom('DRAFT'));

  static SearchCriteria header(String field, String value) {
    if (!RegExp(r'^[!-9;-~]+$').hasMatch(field)) {
      throw ArgumentError.value(field, 'field');
    }
    return SearchCriteria._(
      (c) => c
        ..atom('HEADER')
        ..string(field)
        ..string(value),
    );
  }

  static SearchCriteria and(List<SearchCriteria> criteria) =>
      SearchCriteria._((c) {
        for (final criterion in criteria) {
          criterion._apply(c);
        }
      });

  void applyTo(ImapCommand command) => _apply(command);

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _searchDate(DateTime d) =>
      '${d.day}-${_months[d.month - 1]}-${d.year}';
}

/// How STORE changes flags.
enum FlagChange { add, remove, replace }

/// QRESYNC parameters for SELECT (RFC 7162 3.2.5): what the client has
/// cached, so the server can send only what changed.
final class QresyncParameters {
  const QresyncParameters({
    required this.uidValidity,
    required this.highestModSeq,
    this.knownUids,
  });

  final int uidValidity;
  final int highestModSeq;
  final SequenceSet? knownUids;
}
