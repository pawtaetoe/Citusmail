// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'authentication_results.dart';

/// How worried to be, in increasing order.
enum TrustLevel {
  /// Nothing found.
  ok,

  /// Something unusual; worth a second look.
  caution,

  /// Typical of scams: shown in red, links and risky files need an extra
  /// confirmation.
  danger;

  TrustLevel max(TrustLevel other) => index >= other.index ? this : other;
}

/// What a finding is about, so the app can choose an icon or wording.
enum FindingKind {
  /// The user's server could not verify the sender's domain (DMARC).
  failedVerification,

  /// The display name claims a company that doesn't own the address.
  impersonatedBrand,

  /// The sender's domain imitates a company or the user's own domain.
  lookalikeDomain,

  /// The domain mixes alphabets to look like another.
  mixedScripts,

  /// The display name shows a different email address.
  addressInName,

  /// A link shows one address and goes to another.
  deceptiveLink,

  /// An attachment can run code.
  riskyAttachment,
}

/// One reason for concern, in words for the user.
final class TrustFinding {
  const TrustFinding(this.kind, this.level, this.message);

  final FindingKind kind;
  final TrustLevel level;

  /// A sentence for the user ("The sender claims to be PayPal, but ...").
  final String message;

  @override
  String toString() => 'TrustFinding(${kind.name}, ${level.name}: $message)';
}

/// What is known about one link in the message.
final class LinkVerdict {
  const LinkVerdict(this.link, this.level, this.reasons);

  final Uri link;
  final TrustLevel level;

  /// Sentences for the user, shown before the link opens.
  final List<String> reasons;
}

/// What is known about one attachment.
final class AttachmentVerdict {
  const AttachmentVerdict(this.fileName, this.level, this.reason);

  final String fileName;
  final TrustLevel level;
  final String reason;
}

/// The result of checking one message. Built on the device; nothing about
/// the message leaves it.
final class TrustReport {
  TrustReport({
    List<TrustFinding> findings = const [],
    Map<String, LinkVerdict> links = const {},
    Map<String, AttachmentVerdict> attachments = const {},
    this.verified = false,
    List<AuthResult> dkimPasses = const [],
  }) : findings = List.unmodifiable(findings),
       dkimPasses = List.unmodifiable(dkimPasses),
       _links = Map.unmodifiable(links),
       _attachments = Map.unmodifiable(attachments);

  static final empty = TrustReport();

  /// Message-wide reasons for concern, most serious first.
  final List<TrustFinding> findings;

  /// Whether the user's own server verified the sender's domain (DMARC
  /// pass, or a DKIM signature from that domain).
  final bool verified;

  /// DKIM signatures the user's own server checked and found valid, from
  /// any domain (a newsletter service signs with its own). Used to trust
  /// signed headers such as one-click unsubscribe.
  final List<AuthResult> dkimPasses;

  final Map<String, LinkVerdict> _links;
  final Map<String, AttachmentVerdict> _attachments;

  /// The worst finding's level. A link that is only odd on its own (a
  /// newsletter's tracking redirect) doesn't raise it: it is flagged when
  /// tapped.
  TrustLevel get level =>
      findings.fold(TrustLevel.ok, (level, f) => level.max(f.level));

  /// The verdict for [link], or null if nothing is wrong with it.
  LinkVerdict? link(Uri link) => _links[link.toString()];

  /// The verdict for the attachment saved as [fileName], or null.
  AttachmentVerdict? attachment(String fileName) => _attachments[fileName];

  Iterable<LinkVerdict> get links => _links.values;
  Iterable<AttachmentVerdict> get attachments => _attachments.values;
}
