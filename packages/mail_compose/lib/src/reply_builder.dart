// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_view/mail_view.dart';

import 'draft.dart';

/// Starts replies and forwards from a message the user is reading.
final class ReplyBuilder {
  ReplyBuilder(this._store);

  final MailStore _store;

  /// Quotes longer than this are cut.
  static const maxQuoteLength = 100000;

  /// The longest References header kept (oldest ids are dropped).
  static const maxReferences = 20;

  /// Reply to the sender (or the Reply-To address).
  Draft reply(StoredMessage message, MessageView view) =>
      _reply(message, view, all: false);

  /// Reply to the sender and everyone else on the message, except the
  /// user's own addresses.
  Draft replyAll(StoredMessage message, MessageView view) =>
      _reply(message, view, all: true);

  /// Forward with the original's attachments.
  Draft forward(StoredMessage message, MessageView view) {
    final header = StringBuffer('---------- Forwarded message ----------\n');
    if (message.from case final from?) {
      header.writeln('From: ${_display(from)}');
    }
    header.writeln('Date: ${_date(message.sentAt ?? message.receivedAt)}');
    header.writeln('Subject: ${message.subject ?? ''}');
    final to = _store.messages.addresses(message.id, 'to');
    if (to.isNotEmpty) header.writeln('To: ${to.map(_display).join(', ')}');
    return Draft(
      accountId: message.accountId,
      subject: _prefixed('Fwd: ', message.subject),
      body: '\n\n$header\n${_text(view)}',
      attachments: [
        for (final a in view.attachments)
          DraftAttachment(
            fileName: a.fileName,
            mimeType: a.mimeType,
            bytes: a.bytes(),
          ),
      ],
    );
  }

  Draft _reply(StoredMessage message, MessageView view, {required bool all}) {
    final own = {
      for (final account in _store.accounts.all()) account.email.toLowerCase(),
    };
    bool isOwn(MailAddress a) => own.contains(a.address.toLowerCase());

    final replyTo = _store.messages.addresses(message.id, 'reply_to');
    final target = replyTo.isNotEmpty ? replyTo : [?message.from];
    final seen = <String>{};
    List<MailAddress> unique(Iterable<MailAddress> list) => [
      for (final a in list)
        if (!isOwn(a) && seen.add(a.address.toLowerCase())) a,
    ];

    var to = unique(target);
    var cc = const <MailAddress>[];
    if (all) {
      to = [...to, ...unique(_store.messages.addresses(message.id, 'to'))];
      cc = unique(_store.messages.addresses(message.id, 'cc'));
    }
    // Replying to one's own sent message: reply to its recipients instead.
    if (to.isEmpty) to = unique(_store.messages.addresses(message.id, 'to'));

    final messageId = message.messageId;
    final references = [
      ...message.references,
      if (messageId != null && !message.references.contains(messageId))
        messageId,
    ];
    final from = message.from;
    final intro =
        'On ${_date(message.sentAt ?? message.receivedAt)}, ${from == null ? 'someone' : _display(from)} wrote:';
    return Draft(
      accountId: message.accountId,
      to: to,
      cc: cc,
      subject: _prefixed('Re: ', message.subject),
      body: '\n\n$intro\n${_quote(_text(view))}',
      inReplyTo: messageId,
      references: references.length > maxReferences
          ? references.sublist(references.length - maxReferences)
          : references,
      answeredMessageId: message.id,
    );
  }

  /// The original's text for quoting: its plain-text version exactly as
  /// written when there is one, else the text of the (safe) HTML view.
  static String _text(MessageView view) {
    final plain = view.message.textBody?.decodeText().text;
    final text = (plain ?? view.body.plainText).trimRight();
    return text.length > maxQuoteLength
        ? text.substring(0, maxQuoteLength)
        : text;
  }

  static String _quote(String text) =>
      text.split('\n').map((line) => line.isEmpty ? '>' : '> $line').join('\n');

  /// `Re: ` once: not `Re: Re: Re:`.
  static String _prefixed(String prefix, String? subject) {
    final text = subject?.trim() ?? '';
    final bare = prefix.trim().toLowerCase();
    return text.toLowerCase().startsWith(bare) ? text : '$prefix$text';
  }

  static String _display(MailAddress a) {
    final name = a.displayName?.trim();
    return name == null || name.isEmpty ? a.address : '$name <${a.address}>';
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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

  /// `Tue, 20 Oct 2026 at 09:01`, in local time.
  static String _date(DateTime when) {
    final d = when.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year} '
        'at ${two(d.hour)}:${two(d.minute)}';
  }
}
