// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:typed_data';

import '../mime/address.dart';
import '../mime/content_type.dart';
import '../mime/encoded_word.dart';
import '../mime/mail_date.dart';
import '../mime/message_id.dart';
import '../net/mail_exception.dart';
import 'imap_response.dart';
import 'imap_value.dart';
import 'mailbox_name.dart';
import 'sequence_set.dart';

/// Server capabilities, upper case (e.g. `IDLE`, `CONDSTORE`, `AUTH=PLAIN`).
final class ImapCapabilities {
  ImapCapabilities(Iterable<String> names)
    : names = Set.unmodifiable(names.map((n) => n.toUpperCase()));

  factory ImapCapabilities.fromValues(List<ImapValue> values) =>
      ImapCapabilities(values.map((v) => v.asText).whereType<String>());

  static final ImapCapabilities none = ImapCapabilities(const []);

  final Set<String> names;

  bool has(String name) => names.contains(name.toUpperCase());

  bool supportsAuth(String mechanism) => has('AUTH=$mechanism');

  @override
  String toString() => names.join(' ');
}

/// Special folders (RFC 6154). Choose folders by this, never by name:
/// Namecheap, for example, has a plain "INBOX.Junk" next to the real
/// \Junk folder "INBOX.spam".
enum SpecialUse { all, archive, drafts, flagged, junk, sent, trash, important }

/// One folder from LIST.
final class ImapMailboxInfo {
  ImapMailboxInfo({
    required this.encodedName,
    required this.delimiter,
    required Set<String> attributes,
  }) : attributes = Set.unmodifiable(attributes.map((a) => a.toLowerCase()));

  /// Parses `* LIST (attributes) "delimiter" name`.
  static ImapMailboxInfo? fromResponse(ImapUntaggedData response) {
    final v = response.values;
    if (v.length < 3) return null;
    final attributes = v[0].asList
        ?.map((a) => a.asText)
        .whereType<String>()
        .toSet();
    final name = v[2].asText;
    if (attributes == null || name == null) return null;
    return ImapMailboxInfo(
      encodedName: name,
      delimiter: v[1].asText,
      attributes: attributes,
    );
  }

  /// The name as the server knows it (modified UTF-7). Use this in commands.
  final String encodedName;

  /// Hierarchy separator, or null for a flat namespace.
  final String? delimiter;

  /// Lower case, e.g. `\noselect`, `\haschildren`, `\sent`.
  final Set<String> attributes;

  /// Human-readable name.
  String get name => MailboxNameCodec.decode(encodedName);

  bool get isInbox => encodedName.toUpperCase() == 'INBOX';

  /// Cannot hold messages (a pure container).
  bool get isSelectable =>
      !attributes.contains(r'\noselect') &&
      !attributes.contains(r'\nonexistent');

  SpecialUse? get specialUse {
    for (final use in SpecialUse.values) {
      if (attributes.contains('\\${use.name}')) return use;
    }
    return null;
  }

  @override
  String toString() =>
      'ImapMailboxInfo($name${specialUse == null ? '' : ' ${specialUse!.name}'})';
}

/// STATUS results (RFC 9051 6.3.11). Missing items are null.
final class MailboxStatus {
  const MailboxStatus({
    this.messages,
    this.uidNext,
    this.uidValidity,
    this.unseen,
    this.highestModSeq,
    this.size,
  });

  static MailboxStatus fromValues(List<ImapValue> items) {
    final map = <String, int>{};
    for (var i = 0; i + 1 < items.length; i += 2) {
      final key = items[i].asText?.toUpperCase();
      final value = items[i + 1].asNumber;
      if (key != null && value != null) map[key] = value;
    }
    return MailboxStatus(
      messages: map['MESSAGES'],
      uidNext: map['UIDNEXT'],
      uidValidity: map['UIDVALIDITY'],
      unseen: map['UNSEEN'],
      highestModSeq: map['HIGHESTMODSEQ'],
      size: map['SIZE'],
    );
  }

  final int? messages;
  final int? uidNext;
  final int? uidValidity;
  final int? unseen;
  final int? highestModSeq;
  final int? size;
}

/// State of a folder after SELECT or EXAMINE.
final class SelectedMailbox {
  SelectedMailbox({
    required this.name,
    required this.readOnly,
    required this.exists,
    required this.uidValidity,
    this.uidNext,
    this.highestModSeq,
    this.flags = const {},
    this.permanentFlags = const {},
    this.vanished,
    this.changedMessages = const [],
  });

  final String name;
  final bool readOnly;

  /// Number of messages.
  final int exists;

  /// If this differs from what was cached, all cached UIDs are invalid and
  /// the folder must be downloaded again (RFC 9051 2.3.1.1).
  final int uidValidity;
  final int? uidNext;

  /// Null when the server does not track changes for this folder
  /// (NOMODSEQ or no CONDSTORE); then only full resyncs are possible.
  final int? highestModSeq;
  final Set<String> flags;
  final Set<String> permanentFlags;

  /// QRESYNC: UIDs removed since the given mod-sequence.
  final SequenceSet? vanished;

  /// QRESYNC: messages whose flags changed since the given mod-sequence.
  final List<FetchedMessage> changedMessages;
}

/// A mailbox address from an IMAP ENVELOPE, decoded.
final class ImapEnvelope {
  const ImapEnvelope({
    this.date,
    this.subject,
    this.from = const [],
    this.sender = const [],
    this.replyTo = const [],
    this.to = const [],
    this.cc = const [],
    this.bcc = const [],
    this.inReplyTo,
    this.messageId,
  });

  /// Parses the 10-item ENVELOPE list (RFC 9051 7.5.2).
  static ImapEnvelope? fromValue(ImapValue value) {
    final v = value.asList;
    if (v == null || v.length < 10) return null;
    String? text(ImapValue item) => item.asText;
    final subject = text(v[1]);
    final dateText = text(v[0]);
    return ImapEnvelope(
      date: dateText == null ? null : const MailDateParser().parse(dateText),
      subject: subject == null
          ? null
          : const EncodedWordDecoder().decode(subject).text,
      from: _addresses(v[2]),
      sender: _addresses(v[3]),
      replyTo: _addresses(v[4]),
      to: _addresses(v[5]),
      cc: _addresses(v[6]),
      bcc: _addresses(v[7]),
      inReplyTo: text(v[8]) == null
          ? null
          : const MessageIds().parseSingle(text(v[8])!),
      messageId: text(v[9]) == null
          ? null
          : const MessageIds().parseSingle(text(v[9])!),
    );
  }

  final MailDate? date;
  final String? subject;
  final List<MailAddress> from;
  final List<MailAddress> sender;
  final List<MailAddress> replyTo;
  final List<MailAddress> to;
  final List<MailAddress> cc;
  final List<MailAddress> bcc;
  final String? inReplyTo;
  final String? messageId;

  /// Address lists are ((name adl mailbox host) ...). Group markers (host
  /// NIL) are skipped; their members are kept.
  static List<MailAddress> _addresses(ImapValue value) {
    final list = value.asList;
    if (list == null) return const [];
    final result = <MailAddress>[];
    for (final entry in list) {
      final parts = entry.asList;
      if (parts == null || parts.length < 4) continue;
      final mailbox = parts[2].asText;
      final host = parts[3].asText;
      if (mailbox == null || host == null) continue; // group start/end
      final name = parts[0].asText;
      result.add(
        MailAddress(
          localPart: mailbox,
          domain: host,
          displayName: name == null || name.isEmpty
              ? null
              : const EncodedWordDecoder().decode(name).text,
        ),
      );
    }
    return List.unmodifiable(result);
  }
}

/// One node of a BODYSTRUCTURE, with its IMAP section number.
final class ImapBodyPart {
  ImapBodyPart({
    required this.section,
    required this.contentType,
    this.contentId,
    this.encoding,
    this.size = 0,
    this.lines,
    this.disposition,
    List<ImapBodyPart> children = const [],
    this.embeddedEnvelope,
    this.embeddedBody,
  }) : children = List.unmodifiable(children);

  /// e.g. `1.2`; empty for a multipart root.
  final String section;
  final ContentType contentType;
  final String? contentId;
  final String? encoding;

  /// Size in bytes as transmitted (still encoded).
  final int size;
  final int? lines;
  final ContentDisposition? disposition;
  final List<ImapBodyPart> children;
  final ImapEnvelope? embeddedEnvelope;
  final ImapBodyPart? embeddedBody;

  bool get isMultipart => contentType.isMultipart;

  String? get filename {
    final raw = disposition?.filename ?? contentType.parameters['name'];
    return raw == null ? null : MimeFieldParser.decodeFilename(raw);
  }

  bool get isAttachment {
    if (isMultipart || embeddedBody != null) return false;
    final d = disposition;
    if (d != null) return d.isAttachment;
    return filename != null;
  }

  Iterable<ImapBodyPart> get allParts sync* {
    yield this;
    for (final child in children) {
      yield* child.allParts;
    }
  }

  /// Parses BODYSTRUCTURE (or BODY) at the top level of a message.
  static ImapBodyPart? fromValue(ImapValue value) =>
      _parse(value, '', depth: 0, messageRoot: true);

  /// [messageRoot] is true for the body of a message (top level or inside a
  /// message/rfc822 part): a single-part message body is section "1" (or
  /// "N.1" when embedded in part N), as RFC 9051 6.4.5 numbers them.
  static ImapBodyPart? _parse(
    ImapValue value,
    String prefix, {
    required int depth,
    bool messageRoot = false,
  }) {
    final v = value.asList;
    if (v == null || v.isEmpty || depth > 50) return null;

    if (v.first is ImapList) {
      // Multipart: (part part ... "subtype" [params ...])
      final children = <ImapBodyPart>[];
      var i = 0;
      for (; i < v.length && v[i] is ImapList; i++) {
        final section = prefix.isEmpty ? '${i + 1}' : '$prefix.${i + 1}';
        final child = _parse(v[i], section, depth: depth + 1);
        if (child != null) children.add(child);
      }
      final subtype = i < v.length ? v[i].asText ?? 'mixed' : 'mixed';
      final params = i + 1 < v.length
          ? _parameters(v[i + 1])
          : MimeParameters.none;
      final disposition = i + 2 < v.length ? _disposition(v[i + 2]) : null;
      return ImapBodyPart(
        section: prefix,
        contentType: ContentType('multipart', subtype, params),
        disposition: disposition,
        children: children,
      );
    }

    // Single part: type subtype params id description encoding size ...
    if (v.length < 7) return null;
    final type = v[0].asText ?? 'application';
    final subtype = v[1].asText ?? 'octet-stream';
    final contentType = ContentType(type, subtype, _parameters(v[2]));
    final section = messageRoot ? (prefix.isEmpty ? '1' : '$prefix.1') : prefix;
    var next = 7;
    int? lines;
    ImapEnvelope? envelope;
    ImapBodyPart? embedded;
    if (contentType.isEmbeddedMessage && v.length >= 10) {
      envelope = ImapEnvelope.fromValue(v[7]);
      embedded = _parse(v[8], section, depth: depth + 1, messageRoot: true);
      lines = v[9].asNumber;
      next = 10;
    } else if (contentType.isText && v.length >= 8) {
      lines = v[7].asNumber;
      next = 8;
    }
    // Extension data: md5, disposition, language, location.
    final disposition = next + 1 < v.length ? _disposition(v[next + 1]) : null;
    final id = v[3].asText;
    return ImapBodyPart(
      section: section,
      contentType: contentType,
      contentId: id?.replaceAll(RegExp(r'^<|>$'), ''),
      encoding: v[5].asText?.toLowerCase(),
      size: v[6].asNumber ?? 0,
      lines: lines,
      disposition: disposition,
      embeddedEnvelope: envelope,
      embeddedBody: embedded,
    );
  }

  /// ("name" "value" ...) -> parameters, decoding RFC 2231 forms that some
  /// servers pass through unchanged.
  static MimeParameters _parameters(ImapValue value) {
    final list = value.asList;
    if (list == null) return MimeParameters.none;
    final text = StringBuffer();
    for (var i = 0; i + 1 < list.length; i += 2) {
      final name = list[i].asText;
      final val = list[i + 1].asText;
      if (name == null || val == null || name.contains(RegExp(r'[;="\s]'))) {
        continue;
      }
      text.write(
        '; $name="${val.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
      );
    }
    return const MimeFieldParser().parseParameters(text.toString(), []);
  }

  static ContentDisposition? _disposition(ImapValue value) {
    final list = value.asList;
    if (list == null || list.isEmpty) return null;
    final type = list.first.asText;
    if (type == null) return null;
    return ContentDisposition(
      type,
      list.length > 1 ? _parameters(list[1]) : MimeParameters.none,
    );
  }
}

/// The data of one FETCH response. Items not requested are null.
final class FetchedMessage {
  FetchedMessage({
    required this.sequence,
    this.uid,
    this.flags,
    this.internalDate,
    this.size,
    this.modSeq,
    this.envelope,
    this.bodyStructure,
    Map<String, Uint8List> sections = const {},
  }) : sections = Map.unmodifiable(sections);

  /// Parses `* n FETCH (name value ...)`.
  static FetchedMessage fromResponse(ImapUntaggedData response) {
    final items = response.values.isNotEmpty
        ? response.values.first.asList ?? const []
        : const <ImapValue>[];
    int? uid, size, modSeq;
    Set<String>? flags;
    DateTime? internalDate;
    ImapEnvelope? envelope;
    ImapBodyPart? body;
    final sections = <String, Uint8List>{};
    for (var i = 0; i + 1 < items.length; i += 2) {
      final name = items[i].asText?.toUpperCase() ?? '';
      final value = items[i + 1];
      switch (name) {
        case 'UID':
          uid = value.asNumber;
        case 'FLAGS':
          flags = value.asList
              ?.map((f) => f.asText)
              .whereType<String>()
              .toSet();
        case 'INTERNALDATE':
          internalDate = parseInternalDate(value.asText ?? '');
        case 'RFC822.SIZE':
          size = value.asNumber;
        case 'MODSEQ':
          modSeq = value.asList?.firstOrNull?.asNumber;
        case 'ENVELOPE':
          envelope = ImapEnvelope.fromValue(value);
        case 'BODYSTRUCTURE' || 'BODY':
          body = ImapBodyPart.fromValue(value);
        default:
          final section = _sectionName(name);
          if (section != null) {
            sections[section] = value.asBytes ?? Uint8List(0);
          }
      }
    }
    return FetchedMessage(
      sequence: response.number ?? 0,
      uid: uid,
      flags: flags,
      internalDate: internalDate,
      size: size,
      modSeq: modSeq,
      envelope: envelope,
      bodyStructure: body,
      sections: sections,
    );
  }

  /// Message sequence number at the time of the response.
  final int sequence;
  final int? uid;
  final Set<String>? flags;
  final DateTime? internalDate;
  final int? size;
  final int? modSeq;
  final ImapEnvelope? envelope;
  final ImapBodyPart? bodyStructure;

  /// Body sections by name, e.g. `''` (whole message), `HEADER`, `1.2`.
  final Map<String, Uint8List> sections;

  bool hasFlag(String flag) =>
      flags?.any((f) => f.toLowerCase() == flag.toLowerCase()) ?? false;

  /// `BODY[1.2]<0>` / `BINARY[1]` -> `1.2` / `1`; null for other names.
  static String? _sectionName(String item) {
    final match = RegExp(r'^(?:BODY|BINARY)\[([^\]]*)\](?:<\d+>)?$')
        .firstMatch(item);
    return match?.group(1);
  }

  static const _months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];

  /// INTERNALDATE: `17-Jul-1996 02:44:25 -0700` (day may be space-padded).
  static DateTime? parseInternalDate(String text) {
    final m = RegExp(
      r'^\s*(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})$',
    ).firstMatch(text);
    if (m == null) return null;
    final month = _months.indexOf(m.group(2)!.toUpperCase()) + 1;
    if (month == 0) return null;
    final offset = Duration(
      hours: int.parse(m.group(8)!),
      minutes: int.parse(m.group(9)!),
    );
    final wall = DateTime.utc(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
    return m.group(7) == '+' ? wall.subtract(offset) : wall.add(offset);
  }
}

/// Result of SEARCH / ESEARCH.
final class SearchResult {
  const SearchResult(this.matches, {this.highestModSeq});

  final SequenceSet matches;

  /// With CONDSTORE: the highest mod-sequence of the matches.
  final int? highestModSeq;
}

/// UIDs assigned by APPEND, COPY or MOVE (UIDPLUS, RFC 4315).
final class UidMapping {
  const UidMapping(this.uidValidity, this.sourceUids, this.destinationUids);

  /// From `[APPENDUID v uid]` or `[COPYUID v src dst]`.
  static UidMapping? fromCode(ImapResponseCode? code) {
    if (code == null) return null;
    final args = code.arguments;
    if (code.name == 'APPENDUID' && args.length >= 2) {
      final validity = args[0].asNumber;
      final uids = SequenceSet.tryParse(args[1].asText ?? '');
      if (validity == null || uids == null) return null;
      return UidMapping(validity, null, uids);
    }
    if (code.name == 'COPYUID' && args.length >= 3) {
      final validity = args[0].asNumber;
      final source = SequenceSet.tryParse(args[1].asText ?? '');
      final destination = SequenceSet.tryParse(args[2].asText ?? '');
      if (validity == null || source == null || destination == null) {
        return null;
      }
      return UidMapping(validity, source, destination);
    }
    return null;
  }

  final int uidValidity;
  final SequenceSet? sourceUids;
  final SequenceSet destinationUids;
}

/// The server rejected a command (tagged NO or BAD).
final class ImapCommandException extends MailException {
  ImapCommandException(this.command, this.status, this.code, String serverText)
    : serverText = _shorten(serverText),
      super(
        '$command failed: ${status.name.toUpperCase()}'
        '${code == null ? '' : ' $code'} ${_shorten(serverText)}',
      );

  static String _shorten(String text) =>
      text.length > 300 ? text.substring(0, 300) : text;

  /// The command name only (never its arguments, which may be secret).
  final String command;
  final ImapStatus status;
  final ImapResponseCode? code;

  /// The server's explanation, shortened.
  final String serverText;
}

/// Login was refused (wrong credentials, or the server requires another
/// method). The password is not part of this error.
final class ImapAuthenticationException extends MailException {
  ImapAuthenticationException(super.message, {this.code});

  final ImapResponseCode? code;
}
