// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Mail protocols written from scratch in pure Dart: MIME, IMAP and SMTP.
///
/// Filled in from Stage 2 onwards. Security rules for everything in here:
/// - Every connection uses TLS with full certificate and hostname checks.
/// - Plain-text connections and STARTTLS downgrades are refused.
/// - Credentials and message content are never written to logs.
library;

export 'src/charset/charset.dart' show Charset;
export 'src/charset/charsets.dart';
export 'src/charset/text_decoder.dart';
export 'src/imap/imap_client.dart';
export 'src/imap/imap_command.dart';
export 'src/imap/imap_requests.dart';
export 'src/imap/imap_response.dart';
export 'src/imap/imap_response_reader.dart';
export 'src/imap/imap_results.dart';
export 'src/imap/imap_value.dart';
export 'src/imap/mailbox_name.dart';
export 'src/imap/sequence_set.dart';
export 'src/mime/address.dart';
export 'src/mime/builder/body_encoder.dart';
export 'src/mime/builder/header_encoder.dart';
export 'src/mime/builder/message_builder.dart';
export 'src/mime/builder/outgoing_message.dart';
export 'src/mime/content_type.dart';
export 'src/mime/disposition_notification.dart';
export 'src/mime/encoded_word.dart' show DecodedHeaderText, EncodedWordDecoder;
export 'src/mime/header.dart';
export 'src/mime/mail_date.dart';
export 'src/mime/message_id.dart';
export 'src/mime/mime_defect.dart';
export 'src/mime/mime_message.dart';
export 'src/mime/mime_parser.dart';
export 'src/mime/mime_part.dart';
export 'src/mime/transfer_encoding.dart';
export 'src/net/line_source.dart';
export 'src/net/mail_exception.dart';
export 'src/net/mail_socket.dart';
export 'src/net/server_endpoint.dart';
export 'src/smtp/smtp_client.dart';
export 'src/smtp/smtp_reply.dart';

/// Version of this protocol library, reported nowhere (no ID command, no
/// User-Agent) and kept only for local diagnostics.
const String mailProtocolVersion = '0.1.0';
