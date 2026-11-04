// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';

/// A message the user sent and is waiting for an answer to ("Remind me if
/// no reply").
final class AwaitedMessage {
  AwaitedMessage({
    required this.messageId,
    this.inReplyTo,
    List<String> references = const [],
    List<String> recipients = const [],
  }) : references = List.unmodifiable(references),
       recipients = {for (final r in recipients) _address(r)};

  /// Its Message-ID, without brackets.
  final String messageId;

  /// What it answered, if it was itself a reply.
  final String? inReplyTo;
  final List<String> references;

  /// Who it went to (To and Cc), lower case.
  final Set<String> recipients;

  /// The conversation it belongs to: the first message of the thread it
  /// answered, or itself.
  String get threadRoot =>
      Replies.threadRoot(inReplyTo: inReplyTo, references: references) ??
      messageId;
}

/// A message that arrived after one the user sent, and might answer it.
final class ReplyCandidate {
  const ReplyCandidate({
    this.messageId,
    this.inReplyTo,
    this.references = const [],
    this.from,
    this.subject,
    this.headers = const {},
  });

  final String? messageId;
  final String? inReplyTo;
  final List<String> references;
  final MailAddress? from;
  final String? subject;

  /// Stored headers, lower-case names (`auto-submitted`, `precedence`,
  /// `x-autoreply`, `content-type`...).
  final Map<String, List<String>> headers;
}

/// Whether a message answers one the user sent, for follow-up reminders.
/// Pure and on the device: it reads only the threading headers (In-Reply-To
/// and References), the sender and a few headers that mark automatic mail.
///
/// A reply is a message
///
/// - that names the sent message in In-Reply-To or References, or
/// - that continues the same conversation (the same first message in
///   References) and comes from someone the message went to;
///
/// and that is not from the user, nor written by a machine: out-of-office
/// and other automatic replies (`Auto-Submitted`, `X-Autoreply`,
/// `Precedence: auto_reply`, "Out of office" subjects), bounces and read
/// receipts (reports) don't count. A subject alone never makes a reply: a
/// mailing list quoting the same words is not an answer.
abstract final class Replies {
  /// Whether [m] answers [sent]. [ownAddresses] are the user's addresses
  /// (any case).
  static bool answers(
    ReplyCandidate m,
    AwaitedMessage sent, {
    Set<String> ownAddresses = const {},
  }) {
    if (m.messageId == sent.messageId) return false;
    if (isFromSelf(m, ownAddresses) || isAutomatic(m)) return false;
    final names = _names(m);
    if (names.contains(sent.messageId)) return true;
    // Same conversation, from someone it went to (who may have answered
    // an earlier message of the thread).
    final root = threadRoot(inReplyTo: m.inReplyTo, references: m.references);
    final from = m.from;
    return root != null &&
        root == sent.threadRoot &&
        from != null &&
        sent.recipients.contains(_address(from.address));
  }

  /// Whether [m] comes from one of [ownAddresses].
  static bool isFromSelf(ReplyCandidate m, Set<String> ownAddresses) {
    final from = m.from;
    if (from == null) return false;
    final own = {for (final a in ownAddresses) _address(a)};
    return own.contains(_address(from.address));
  }

  /// Whether [m] was written by a machine on someone's behalf: an
  /// out-of-office or other automatic reply, a bounce, a read receipt.
  static bool isAutomatic(ReplyCandidate m) =>
      isAutoReply(m) || _isReport(m) || _isBounce(m);

  /// An automatic reply (RFC 3834 `Auto-Submitted`, the older
  /// `X-Autoreply` / `X-Autorespond`, `Precedence: auto_reply`), or a
  /// subject that says so ("Out of office", "Automatic reply", and the
  /// same in a few common languages).
  static bool isAutoReply(ReplyCandidate m) {
    final submitted = _token(m, 'auto-submitted');
    if (submitted != null && submitted != 'no') return true;
    if (_header(m, 'x-autoreply') != null) return true;
    if (_header(m, 'x-autorespond') != null) return true;
    if (_token(m, 'precedence') == 'auto_reply') return true;
    final subject = (m.subject ?? '').trim();
    return _autoSubjects.any((p) => p.hasMatch(subject));
  }

  /// The first message of the conversation: the first References entry,
  /// or what it answers.
  static String? threadRoot({
    String? inReplyTo,
    List<String> references = const [],
  }) {
    for (final r in references) {
      final id = _id(r);
      if (id.isNotEmpty) return id;
    }
    final parent = inReplyTo == null ? '' : _id(inReplyTo);
    return parent.isEmpty ? null : parent;
  }

  static Set<String> _names(ReplyCandidate m) => {
    if (m.inReplyTo case final parent?) _id(parent),
    for (final r in m.references) _id(r),
  }..remove('');

  static bool _isReport(ReplyCandidate m) => (_header(m, 'content-type') ?? '')
      .toLowerCase()
      .contains('multipart/report');

  static bool _isBounce(ReplyCandidate m) {
    final local = m.from?.localPart.toLowerCase() ?? '';
    return local == 'mailer-daemon' || local == 'postmaster';
  }

  // "Out of office", "Out of Office: …", "Automatic reply: …",
  // "Auto-Reply", "Autoreply", "Auto: …" (Outlook in some languages),
  // "Abwesenheitsnotiz", "Réponse automatique", "Respuesta automática",
  // "Risposta automatica", "Afwezig", "Automatisch antwoord",
  // "Fuera de la oficina", "Absence".
  static final _autoSubjects = [
    RegExp(r'^out of (the )?office\b', caseSensitive: false),
    RegExp(
      r'^(re:\s*)?(automatic|auto)[- ]?(reply|response)\b',
      caseSensitive: false,
    ),
    RegExp(r'^autoreply\b', caseSensitive: false),
    RegExp(r'^auto:\s', caseSensitive: false),
    RegExp(r'^abwesenheit', caseSensitive: false),
    RegExp(r'^automatische antwort', caseSensitive: false),
    RegExp(r'^r[ée]ponse automatique', caseSensitive: false),
    RegExp(r'^absence\b', caseSensitive: false),
    RegExp(r'^respuesta autom[áa]tica', caseSensitive: false),
    RegExp(r'^fuera de la oficina', caseSensitive: false),
    RegExp(r'^risposta automatica', caseSensitive: false),
    RegExp(r'^automatisch antwoord', caseSensitive: false),
    RegExp(r'^afwezig', caseSensitive: false),
  ];

  static String? _header(ReplyCandidate m, String name) {
    for (final value in m.headers[name] ?? const <String>[]) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String? _token(ReplyCandidate m, String name) =>
      _firstWord.firstMatch(_header(m, name) ?? '')?.group(0)?.toLowerCase();

  static final _firstWord = RegExp(r'^[^\s;(]+');

  static String _id(String raw) {
    var id = raw.trim();
    if (id.startsWith('<')) id = id.substring(1);
    if (id.endsWith('>')) id = id.substring(0, id.length - 1);
    return id.trim();
  }
}

String _address(String a) => a.trim().toLowerCase();
