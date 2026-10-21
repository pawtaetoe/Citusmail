// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../mail_date.dart';
import '../message_id.dart';
import 'body_encoder.dart';
import 'header_encoder.dart';
import 'outgoing_message.dart';

/// Builds RFC 5322 / MIME messages for sending.
///
/// Structure, from the outside in, using only the layers needed:
///   multipart/mixed       (when there are regular attachments)
///   multipart/related     (when the HTML has inline images)
///   multipart/alternative (when there is both text and HTML)
///
/// Privacy: no User-Agent or X-Mailer header, the Date is written in UTC
/// unless [dateOffset] says otherwise, the Message-ID is random, and Bcc
/// recipients appear only in the SMTP envelope.
final class MessageBuilder {
  MessageBuilder({Random? random, this.dateOffset = Duration.zero})
    : _random = random ?? Random.secure();

  final Random _random;

  /// UTC offset written in the Date header.
  final Duration dateOffset;

  static const _headers = HeaderEncoder();
  static const _bodies = BodyEncoder();
  static final _mimeType = RegExp(
    r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
  );

  BuiltMessage build(OutgoingMessage message) {
    if (message.envelopeRecipients.isEmpty) {
      throw const MessageBuildException(
        'a message needs at least one recipient',
      );
    }
    // Validate every address up front, including Bcc (never written).
    for (final address in [
      message.from,
      ...message.envelopeRecipients,
      ?message.replyTo,
    ]) {
      _headers.validateAddress(address);
    }

    final messageId =
        message.messageId ??
        MessageIds.generate(message.from.domain, random: _random);
    final out = StringBuffer()
      ..write(
        'Date: ${MailDate.format(message.date ?? DateTime.now(), offset: dateOffset)}\r\n',
      )
      ..write(_headers.addressList('From', [message.from]));
    if (message.replyTo != null) {
      out.write(_headers.addressList('Reply-To', [message.replyTo!]));
    }
    if (message.to.isNotEmpty) {
      out.write(_headers.addressList('To', message.to));
    }
    if (message.cc.isNotEmpty) {
      out.write(_headers.addressList('Cc', message.cc));
    }
    out
      ..write(_headers.unstructured('Subject', message.subject))
      ..write(_headers.messageIds('Message-ID', [messageId]));
    if (message.inReplyTo != null) {
      out.write(_headers.messageIds('In-Reply-To', [message.inReplyTo!]));
    }
    if (message.references.isNotEmpty) {
      out.write(_headers.messageIds('References', message.references));
    }
    out.write('MIME-Version: 1.0\r\n');

    final body = _buildBody(message);
    final bytes = BytesBuilder(copy: false)
      ..add(ascii.encode(out.toString()))
      ..add(body.headerBytes)
      ..add(const [0x0D, 0x0A])
      ..add(body.content);
    return BuiltMessage(
      bytes: bytes.takeBytes(),
      messageId: messageId,
      recipients: message.envelopeRecipients,
    );
  }

  _Entity _buildBody(OutgoingMessage message) {
    for (final attachment in message.attachments) {
      if (!_mimeType.hasMatch(attachment.mimeType)) {
        throw MessageBuildException(
          'invalid attachment type: ${attachment.mimeType}',
        );
      }
    }
    final inline = message.attachments.where((a) => a.isInline).toList();
    final regular = message.attachments.where((a) => !a.isInline).toList();

    var body = _alternative(message.textBody, message.htmlBody);
    if (inline.isNotEmpty && message.htmlBody != null) {
      // RFC 2387: "type" names the root part's type.
      body = _multipart('related', [
        body,
        ...inline.map(_attachment),
      ], extra: '; type="${body.mimeType}"');
    } else {
      regular.addAll(inline); // no HTML to show them in
    }
    if (regular.isNotEmpty) {
      body = _multipart('mixed', [body, ...regular.map(_attachment)]);
    }
    return body;
  }

  _Entity _alternative(String? text, String? html) {
    if (text != null && html != null) {
      return _multipart('alternative', [
        _text(text, 'plain'),
        _text(html, 'html'),
      ]);
    }
    if (html != null) return _text(html, 'html');
    return _text(text ?? '', 'plain');
  }

  _Entity _text(String text, String subtype) {
    final encoded = _bodies.encodeText(text);
    return _Entity(
      'text/$subtype',
      'Content-Type: text/$subtype; charset=utf-8\r\n'
          'Content-Transfer-Encoding: ${encoded.encoding.token}\r\n',
      encoded.bytes,
    );
  }

  _Entity _attachment(OutgoingAttachment attachment) {
    final name = _safeFilename(attachment.filename);
    final headers = StringBuffer()
      ..write(
        'Content-Type: ${attachment.mimeType.toLowerCase()}${_filenameParameter('name', name)}\r\n',
      )
      ..write('Content-Transfer-Encoding: base64\r\n')
      ..write(
        'Content-Disposition: ${attachment.isInline ? 'inline' : 'attachment'}'
        '${_filenameParameter('filename', name)}\r\n',
      );
    if (attachment.contentId != null) {
      headers.write(_headers.messageIds('Content-ID', [attachment.contentId!]));
    }
    return _Entity(
      attachment.mimeType.toLowerCase(),
      headers.toString(),
      BodyEncoder.encodeBase64(attachment.bytes),
    );
  }

  /// `;\r\n name="file.pdf"` for short ASCII names; for others RFC 2231
  /// encoding (`name*=utf-8''...`), split into continuations. Each
  /// parameter goes on its own folded line to keep lines short.
  static String _filenameParameter(String parameter, String filename) {
    final isPlainAscii = filename.runes.every((r) => r >= 0x20 && r <= 0x7E);
    if (isPlainAscii && filename.length < 60) {
      return ';\r\n $parameter="${filename.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    }
    final encoded = utf8.encode(filename).map((b) {
      final isSafe =
          (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          b == 0x2D ||
          b == 0x2E ||
          b == 0x5F;
      return isSafe
          ? String.fromCharCode(b)
          : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    }).join();
    // Split into RFC 2231 continuations of at most 60 characters each,
    // never inside a %XX escape.
    final sections = <String>[];
    var rest = "utf-8''$encoded";
    while (rest.length > 60) {
      var cut = 60;
      if (rest[cut - 1] == '%') cut -= 1;
      if (rest[cut - 2] == '%') cut -= 2;
      sections.add(rest.substring(0, cut));
      rest = rest.substring(cut);
    }
    sections.add(rest);
    if (sections.length == 1) return ';\r\n $parameter*=${sections.single}';
    return [
      for (var i = 0; i < sections.length; i++)
        ';\r\n $parameter*$i*=${sections[i]}',
    ].join();
  }

  /// Removes directory parts, control characters and quotes that could
  /// confuse the recipient's software. Never empty.
  static String _safeFilename(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    final clean = base.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
    return clean.isEmpty || clean == '.' || clean == '..'
        ? 'attachment'
        : clean;
  }

  _Entity _multipart(String subtype, List<_Entity> parts, {String extra = ''}) {
    final boundary = _uniqueBoundary(parts);
    final body = BytesBuilder(copy: false);
    for (final part in parts) {
      body
        ..add(ascii.encode('--$boundary\r\n'))
        ..add(part.headerBytes)
        ..add(const [0x0D, 0x0A])
        ..add(part.content)
        ..add(const [0x0D, 0x0A]);
    }
    body.add(ascii.encode('--$boundary--\r\n'));
    return _Entity(
      'multipart/$subtype',
      'Content-Type: multipart/$subtype; boundary="$boundary"$extra\r\n',
      body.takeBytes(),
    );
  }

  /// A random boundary that does not occur in any of the parts. "=_" can
  /// never appear in base64 or quoted-printable output.
  String _uniqueBoundary(List<_Entity> parts) {
    while (true) {
      final random = List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final boundary = '=_$random';
      final needle = ascii.encode(boundary);
      if (!parts.any(
        (p) => _contains(p.content, needle) || _contains(p.headerBytes, needle),
      )) {
        return boundary;
      }
    }
  }

  static bool _contains(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}

/// A MIME entity being built: its type, header lines and encoded content.
final class _Entity {
  _Entity(this.mimeType, String headers, this.content)
    : headerBytes = ascii.encode(headers);

  final String mimeType;
  final List<int> headerBytes;
  final List<int> content;
}
