// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Something wrong with a message that the parser worked around.
///
/// Mail is untrusted input, so the parser never throws on malformed data.
/// It recovers as browsers and other mail clients do and records a defect.
/// Defects can feed later checks (for example, phishing heuristics) and
/// help debugging, but a message with defects still displays.
enum MimeDefectKind {
  // Structure
  missingHeaderBodySeparator,
  malformedHeaderLine,
  missingBoundary,
  missingClosingBoundary,
  noPartsInMultipart,

  // Limits (hostile or absurd input)
  headerSectionTooLarge,
  tooManyHeaderFields,
  nestingTooDeep,
  tooManyParts,

  // Field values
  invalidContentType,
  invalidParameter,
  invalidEncodedWord,
  invalidAddress,
  invalidDate,

  // Content
  unknownTransferEncoding,
  invalidBase64,
  invalidQuotedPrintable,
  unknownCharset,
}

final class MimeDefect {
  const MimeDefect(this.kind, [this.detail]);

  final MimeDefectKind kind;

  /// Short description for logs and debugging. Never contains message
  /// content beyond a header name or a parameter name.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is MimeDefect && other.kind == kind && other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, detail);

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}
