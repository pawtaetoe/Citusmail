// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_view/mail_view.dart';

import 'link_cleaner.dart';
import 'trust_report.dart';

/// What one message tried that the app kept from the sender, found in
/// its stored content: the same things the reader's privacy notice and
/// warning show for it.
final class MessagePrivacy {
  const MessagePrivacy({
    this.trackers = 0,
    this.remoteImages = 0,
    this.trackingLinks = 0,
    this.readReceipt = false,
    this.warned = false,
  });

  /// Reads [view] (and its [trust] report, if it was checked).
  /// [imagesAllowed]: the user chose to always load this sender's images,
  /// so they were not held back (as in the reader, only when the sender
  /// is verified and the message isn't dangerous).
  factory MessagePrivacy.of(
    MessageView view, {
    TrustReport? trust,
    bool imagesAllowed = false,
  }) {
    final body = view.body;
    final imagesShown =
        imagesAllowed &&
        trust != null &&
        trust.verified &&
        trust.level != TrustLevel.danger;
    return MessagePrivacy(
      trackers: body.trackers,
      remoteImages: imagesShown ? 0 : body.remoteImages,
      trackingLinks: trackingLinksIn(body),
      readReceipt: view.message.headers.contains('disposition-notification-to'),
      warned: trust != null && trust.level != TrustLevel.ok,
    );
  }

  /// Tracking pixels, never loaded.
  final int trackers;

  /// Images from the internet, held back until the user loads them.
  final int remoteImages;

  /// Different links carrying tracking parameters ([LinkCleaner]), which
  /// are removed when a link is opened.
  final int trackingLinks;

  /// The sender asked for a read receipt (`Disposition-Notification-To`);
  /// the app never sends one.
  final bool readReceipt;

  /// The phishing checks warned about it.
  final bool warned;

  /// How many different links in [document] carry tracking parameters.
  static int trackingLinksIn(RichDocument document) {
    final links = <Uri>{};
    void inlines(List<Inline> list) {
      for (final inline in list) {
        final link = switch (inline) {
          TextRun(:final link) => link,
          ImageInline(:final link) => link,
          RemoteImageInline(:final link) => link,
          LineBreak() => null,
        };
        if (link != null) links.add(link);
      }
    }

    void blocks(List<Block> list) {
      for (final block in list) {
        switch (block) {
          case ParagraphBlock(inlines: final i) ||
              HeadingBlock(inlines: final i):
            inlines(i);
          case QuoteBlock(:final children):
            blocks(children);
          case ListBlock(:final items):
            items.forEach(blocks);
          case TableBlock(:final rows):
            for (final row in rows) {
              for (final cell in row) {
                blocks(cell.blocks);
              }
            }
          case PreformattedBlock() || RuleBlock():
            break;
        }
      }
    }

    blocks(document.blocks);
    return links.where((l) => LinkCleaner.clean(l).removed.isNotEmpty).length;
  }
}

/// One counted message: who sent it, when it arrived, and what it tried.
final class PrivacyEmail {
  const PrivacyEmail({
    required this.address,
    this.name,
    required this.receivedAt,
    required this.privacy,
  });

  /// The sender's address ('' if it had none).
  final String address;
  final String? name;
  final DateTime receivedAt;
  final MessagePrivacy privacy;
}

/// A sender's tracking: how many of its emails were counted and the
/// trackers in them.
final class SenderTracking {
  const SenderTracking({
    required this.address,
    this.name,
    required this.emails,
    required this.trackers,
  });

  /// Lower case.
  final String address;
  final String? name;
  final int emails;
  final int trackers;

  double get perEmail => emails == 0 ? 0 : trackers / emails;
}

/// What the app kept from senders over a period, counted on the device
/// from the mail whose content is stored.
final class PrivacyReport {
  const PrivacyReport({
    this.messages = 0,
    this.trackers = 0,
    this.remoteImages = 0,
    this.trackingLinks = 0,
    this.readReceipts = 0,
    this.warned = 0,
    this.topTrackers = const [],
  });

  static const empty = PrivacyReport();

  /// Sums [emails] received at or after [since], with the [top] senders
  /// that track the most per email.
  factory PrivacyReport.of(
    Iterable<PrivacyEmail> emails, {
    required DateTime since,
    int top = 5,
  }) {
    var messages = 0, trackers = 0, images = 0, links = 0;
    var receipts = 0, warned = 0;
    final senders = <String, _Sender>{};
    for (final e in emails) {
      if (e.receivedAt.isBefore(since)) continue;
      final p = e.privacy;
      messages++;
      trackers += p.trackers;
      images += p.remoteImages;
      links += p.trackingLinks;
      if (p.readReceipt) receipts++;
      if (p.warned) warned++;
      final address = e.address.trim().toLowerCase();
      if (address.isEmpty) continue;
      final sender = senders.putIfAbsent(address, _Sender.new)
        ..emails += 1
        ..trackers += p.trackers;
      // The newest name the sender used.
      final name = e.name?.trim();
      if (name != null &&
          name.isNotEmpty &&
          (sender.namedAt == null || e.receivedAt.isAfter(sender.namedAt!))) {
        sender
          ..name = name
          ..namedAt = e.receivedAt;
      }
    }
    final ranked = [
      for (final MapEntry(key: address, value: s) in senders.entries)
        if (s.trackers > 0)
          SenderTracking(
            address: address,
            name: s.name,
            emails: s.emails,
            trackers: s.trackers,
          ),
    ]..sort(_mostTracking);
    return PrivacyReport(
      messages: messages,
      trackers: trackers,
      remoteImages: images,
      trackingLinks: links,
      readReceipts: receipts,
      warned: warned,
      topTrackers: List.unmodifiable(ranked.take(top)),
    );
  }

  /// Messages counted.
  final int messages;
  final int trackers;
  final int remoteImages;
  final int trackingLinks;
  final int readReceipts;
  final int warned;

  /// Senders by trackers per email, most first; then by trackers in all.
  final List<SenderTracking> topTrackers;

  static int _mostTracking(SenderTracking a, SenderTracking b) {
    final per = b.perEmail.compareTo(a.perEmail);
    if (per != 0) return per;
    final all = b.trackers.compareTo(a.trackers);
    if (all != 0) return all;
    return a.address.compareTo(b.address);
  }
}

final class _Sender {
  int emails = 0;
  int trackers = 0;
  String? name;
  DateTime? namedAt;
}
