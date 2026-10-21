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

/// Version of this protocol library, reported nowhere (no ID command, no
/// User-Agent) and kept only for local diagnostics.
const String mailProtocolVersion = '0.1.0';
