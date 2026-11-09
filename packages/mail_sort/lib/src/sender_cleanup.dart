// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';

import 'sender_patterns.dart';

/// What kind of mail a sender sends, from the Smart Inbox sorting.
enum SenderKind { newsletter, notification, other }

/// One received message, as the Clean up page counts it.
final class SenderMail {
  const SenderMail({
    required this.messageId,
    required this.from,
    required this.domain,
    required this.at,
    required this.opened,
    required this.category,
    this.canUnsubscribe = false,
  });

  /// The stored message's id.
  final int messageId;
  final MailAddress from;

  /// The registrable domain of [from] (`shop.example` of
  /// `mail.shop.example`), worked out by the caller.
  final String domain;
  final DateTime at;

  /// Whether it was opened (has the read flag).
  final bool opened;
  final MessageCategory category;

  /// Whether it has a `List-Unsubscribe` header.
  final bool canUnsubscribe;
}

/// The mail of one sender: one address, or every no-reply style address
/// of one company (`noreply@`, `alerts@`... at one domain).
final class SenderGroup {
  SenderGroup._({
    required this.key,
    required this.byDomain,
    required this.name,
    required this.addresses,
    required this.messageIds,
    required this.count,
    required this.opened,
    required this.last,
    required this.kind,
    required this.newestId,
    required this.unsubscribeId,
  });

  /// What identifies the group, also in the user's "Keep" list: the
  /// address (lower case), or `@domain` for a company's no-reply senders.
  final String key;

  /// Whether this groups a company's no-reply addresses by domain.
  final bool byDomain;

  /// A display name the sender uses, else the address or domain.
  final String name;

  /// The addresses in the group (lower case), most mail first.
  final List<String> addresses;

  /// The messages counted, newest first; empty when the store did the
  /// counting ([SenderCleanup.groupSenders]).
  final List<int> messageIds;

  /// How many messages were counted.
  final int count;

  /// How many of them were opened.
  final int opened;

  /// When the newest came.
  final DateTime last;
  final SenderKind kind;

  /// The newest message.
  final int newestId;

  /// The newest message that has unsubscribe headers, if any.
  final int? unsubscribeId;

  /// Opened share, 0 to 1.
  double get openRate => count == 0 ? 0 : opened / count;

  bool get canUnsubscribe => unsubscribeId != null;

  /// Newsletters and notifications.
  bool get isBulk => kind != SenderKind.other;

  /// What the group shows under its name: the address, or the domain.
  String get label => byDomain ? key.substring(1) : addresses.first;

  @override
  String toString() => 'SenderGroup($key, $count, opened $opened)';
}

/// How the Clean up page orders senders.
enum SenderOrder {
  /// Most mail first.
  mostMail,

  /// Lowest opened share first, among senders with enough mail for the
  /// share to mean something.
  leastOpened,
}

/// Finds the senders whose mail the user may not want: who sends the most,
/// and whose mail is rarely opened. Runs on the device, on stored mail.
abstract final class SenderCleanup {
  /// How far back mail is counted.
  static const window = Duration(days: 91);

  /// Fewer emails than this say nothing about how often a sender's mail
  /// is opened: one unread email must not top "Least opened".
  static const minForOpenRate = 4;

  /// A sender is "rarely opened" at or below this share.
  static const rarelyOpened = 0.25;

  /// The key of [from]'s group: the address, or `@domain` for a
  /// no-reply style address ([domain] is its registrable domain).
  static String keyOf(MailAddress from, String domain) =>
      AutomatedSender.matches(from) && domain.isNotEmpty
      ? '@${domain.toLowerCase()}'
      : from.address.toLowerCase();

  /// Groups [mail] by sender, leaving out mail older than [window] (from
  /// [now]), the user's own addresses ([own], lower case) and people the
  /// user has written to ([writtenTo], lower case): those are people, not
  /// bulk mail. Groups whose key is in [kept] are left out too. Most mail
  /// first.
  static List<SenderGroup> group(
    Iterable<SenderMail> mail, {
    required DateTime now,
    Set<String> own = const {},
    Set<String> writtenTo = const {},
    Set<String> kept = const {},
  }) {
    final since = now.subtract(window);
    final byKey = <String, List<SenderMail>>{};
    for (final m in mail) {
      if (m.at.isBefore(since)) continue;
      final address = m.from.address.toLowerCase();
      if (!address.contains('@')) continue;
      if (own.contains(address) || writtenTo.contains(address)) continue;
      final key = keyOf(m.from, m.domain);
      if (kept.contains(key)) continue;
      byKey.putIfAbsent(key, () => []).add(m);
    }
    return sort([
      for (final MapEntry(:key, :value) in byKey.entries) _build(key, value),
    ], SenderOrder.mostMail);
  }

  /// Groups senders the store already added up ([SenderStats], one per
  /// address, from `MessageRepository.senderStats` for the mail of the
  /// last [window]) the way [group] groups mail, without reading any
  /// message. [domainOf] gives the registrable domain of an address's
  /// domain (`shop.example` for `mail.shop.example`). Most mail first.
  static List<SenderGroup> groupSenders(
    Iterable<SenderStats> senders, {
    required String Function(String domain) domainOf,
    Set<String> own = const {},
    Set<String> writtenTo = const {},
    Set<String> kept = const {},
  }) {
    final byKey = <String, List<SenderStats>>{};
    for (final s in senders) {
      final address = s.from.address.toLowerCase();
      if (!address.contains('@')) continue;
      if (own.contains(address) || writtenTo.contains(address)) continue;
      final key = keyOf(s.from, domainOf(s.from.domain));
      if (kept.contains(key)) continue;
      byKey.putIfAbsent(key, () => []).add(s);
    }
    return sort([
      for (final MapEntry(:key, :value) in byKey.entries)
        _buildFromStats(key, value),
    ], SenderOrder.mostMail);
  }

  /// One message as a sender's totals of one.
  static SenderStats _one(SenderMail m) => SenderStats(
    from: m.from,
    count: 1,
    opened: m.opened ? 1 : 0,
    newsletters: m.category == MessageCategory.newsletters ? 1 : 0,
    notifications: m.category == MessageCategory.notifications ? 1 : 0,
    last: m.at,
    newestId: m.messageId,
    unsubscribeId: m.canUnsubscribe ? m.messageId : null,
    unsubscribeAt: m.canUnsubscribe ? m.at : null,
  );

  static SenderGroup _build(String key, List<SenderMail> mail) {
    mail.sort((a, b) {
      final c = b.at.compareTo(a.at);
      return c != 0 ? c : b.messageId.compareTo(a.messageId);
    });
    return _buildFromStats(
      key,
      [for (final m in mail) _one(m)],
      messageIds: [for (final m in mail) m.messageId],
    );
  }

  static SenderGroup _buildFromStats(
    String key,
    List<SenderStats> senders, {
    List<int> messageIds = const [],
  }) {
    senders.sort((a, b) {
      final c = b.last.compareTo(a.last);
      return c != 0 ? c : b.newestId.compareTo(a.newestId);
    });
    final perAddress = <String, int>{};
    final names = <String, int>{};
    var count = 0, opened = 0, newsletters = 0, notifications = 0;
    SenderStats? unsubscribe;
    for (final s in senders) {
      perAddress.update(
        s.from.address.toLowerCase(),
        (n) => n + s.count,
        ifAbsent: () => s.count,
      );
      final name = s.from.displayName?.trim();
      if (name != null && name.isNotEmpty) {
        names.update(name, (n) => n + s.count, ifAbsent: () => s.count);
      }
      count += s.count;
      opened += s.opened;
      newsletters += s.newsletters;
      notifications += s.notifications;
      // The newest message with unsubscribe headers.
      if (s.unsubscribeAt case final at?
          when unsubscribe == null || at.isAfter(unsubscribe.unsubscribeAt!)) {
        unsubscribe = s;
      }
    }
    final addresses = perAddress.keys.toList()
      ..sort((a, b) => perAddress[b]!.compareTo(perAddress[a]!));
    final byDomain = key.startsWith('@');
    // The name used most, else what identifies the sender.
    final name = names.isEmpty
        ? (byDomain ? key.substring(1) : addresses.first)
        : (names.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
              .first
              .key;
    // Bulk when at least half of it is.
    final kind = (newsletters + notifications) * 2 < count
        ? SenderKind.other
        : newsletters >= notifications
        ? SenderKind.newsletter
        : SenderKind.notification;
    return SenderGroup._(
      key: key,
      byDomain: byDomain,
      name: name,
      addresses: addresses,
      messageIds: messageIds,
      count: count,
      opened: opened,
      last: senders.first.last,
      kind: kind,
      newestId: senders.first.newestId,
      unsubscribeId: unsubscribe?.unsubscribeId,
    );
  }

  /// [groups] in [order]. "Least opened" puts senders with fewer than
  /// [minForOpenRate] emails last, by volume.
  static List<SenderGroup> sort(List<SenderGroup> groups, SenderOrder order) {
    int byVolume(SenderGroup a, SenderGroup b) {
      final c = b.count.compareTo(a.count);
      if (c != 0) return c;
      final d = b.last.compareTo(a.last);
      return d != 0 ? d : a.key.compareTo(b.key);
    }

    final sorted = [...groups];
    switch (order) {
      case SenderOrder.mostMail:
        sorted.sort(byVolume);
      case SenderOrder.leastOpened:
        sorted.sort((a, b) {
          final enoughA = a.count >= minForOpenRate;
          final enoughB = b.count >= minForOpenRate;
          if (enoughA != enoughB) return enoughA ? -1 : 1;
          if (enoughA) {
            final c = a.openRate.compareTo(b.openRate);
            if (c != 0) return c;
          }
          return byVolume(a, b);
        });
    }
    return sorted;
  }

  /// Whether the user rarely opens [group]'s mail: enough of it, and at
  /// most [rarelyOpened] opened.
  static bool isRarelyOpened(SenderGroup group) =>
      group.count >= minForOpenRate && group.openRate <= rarelyOpened;

  /// How many emails, from how many of [groups], the user rarely opens.
  static ({int emails, int senders}) rarelyOpenedTotal(
    Iterable<SenderGroup> groups,
  ) {
    var emails = 0, senders = 0;
    for (final g in groups.where(isRarelyOpened)) {
      emails += g.count;
      senders++;
    }
    return (emails: emails, senders: senders);
  }

  /// What a bulk action ("Archive all", "Delete all") may touch of
  /// [messages]: never pinned mail.
  static List<StoredMessage> actionable(Iterable<StoredMessage> messages) => [
    for (final m in messages)
      if (!m.flags.flagged) m,
  ];
}
