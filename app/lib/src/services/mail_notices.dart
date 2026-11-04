// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';

import '../app.dart' show appName;

/// How the system shows several notifications of one app.
enum NoticeLayout {
  /// Android: one notification per message, bundled under a summary per
  /// account.
  grouped,

  /// Linux and Windows: separate notifications, so only the newest few
  /// and one "and N more".
  separate,
}

/// What one new-mail notification shows: worked out here, posted by
/// MailNotifier.
final class MailNotice {
  const MailNotice({
    required this.id,
    required this.title,
    required this.body,
    this.preview,
    this.messageId,
    this.code,
    this.lines = const [],
    this.more,
    this.receivedAt,
    this.isSummary = false,
  });

  /// The system's notification id (replaces an earlier one with the same).
  final int id;
  final String title;

  /// One line: the subject, or for a summary the senders.
  final String body;

  /// A short preview of the text, when previews are on.
  final String? preview;

  /// The message a tap opens.
  final int? messageId;

  /// A verification code: the notification gets a Copy code button.
  final String? code;

  /// A summary's lines, "Sender — Subject", newest first.
  final List<String> lines;

  /// A summary's note on what its lines leave out ("and 3 more").
  final String? more;

  final DateTime? receivedAt;
  final bool isSummary;

  /// [body] with the [preview] under it.
  String get text => preview == null ? body : '$body\n$preview';

  /// What a tap hands back (see [MailNotices.messageIdOf]).
  String? get payload => messageId == null ? null : 'message:$messageId';

  /// The Copy code button's action id, when there is a [code].
  String? get copyActionId => code == null || messageId == null
      ? null
      : CopyCodeAction.actionId(messageId!, code!);
}

/// Works out the notifications for new mail of one account.
abstract final class MailNotices {
  /// Separate notifications shown at most ([NoticeLayout.separate]); the
  /// rest are counted in one more.
  static const separateLimit = 5;

  /// Lines in a summary ([NoticeLayout.grouped]).
  static const summaryLines = 6;

  /// Characters of preview at most (about two lines).
  static const previewLength = 140;

  /// The notifications for [mail], in the order to post them (oldest
  /// first, so the newest ends up on top; a summary last).
  ///
  /// With [hideContent] (the app lock is on) only that there is new mail:
  /// no sender, subject, preview or code. Without [previews], sender and
  /// subject only; codes keep their Copy code button.
  static List<MailNotice> build(
    Account account,
    NewMail mail, {
    required NoticeLayout layout,
    bool hideContent = false,
    bool previews = true,
  }) {
    // Mail waiting in the Screener never notifies (NewMailTracker already
    // leaves it out; this keeps it so for any other caller).
    final screened = mail.messages
        .where((m) => m.section == SmartSection.screener)
        .length;
    if (screened > 0) {
      mail = NewMail(mail.accountId, [
        for (final m in mail.messages)
          if (m.section != SmartSection.screener) m,
      ], total: mail.total - screened);
    }
    if (mail.isEmpty) return const [];
    if (hideContent) {
      return [
        MailNotice(
          id: summaryId(account.id),
          title: mail.total == 1 ? 'New mail' : '${mail.total} new emails',
          body: 'Unlock $appName to read ${mail.total == 1 ? 'it' : 'them'}.',
          isSummary: true,
        ),
      ];
    }
    final messages = mail.messages;
    switch (layout) {
      case NoticeLayout.grouped:
        return [
          for (final m in messages) _notice(m, previews: previews),
          if (messages.length > 1 || mail.total > messages.length)
            _summary(account, mail),
        ];
      case NoticeLayout.separate:
        final shown = messages.length > separateLimit
            ? messages.sublist(messages.length - separateLimit)
            : messages;
        final rest = mail.total - shown.length;
        final restSenders = _senders(
          messages.sublist(0, messages.length - shown.length).reversed,
        );
        return [
          for (final m in shown) _notice(m, previews: previews),
          if (rest > 0)
            MailNotice(
              id: summaryId(account.id),
              title: 'And $rest more new ${rest == 1 ? 'email' : 'emails'}',
              body: restSenders.isEmpty
                  ? account.email
                  : '${_joinSenders(restSenders)} · ${account.email}',
              isSummary: true,
            ),
        ];
    }
  }

  static MailNotice _notice(StoredMessage m, {required bool previews}) {
    final sender = senderName(m);
    final subject = m.subject?.trim();
    final code = m.shownCode;
    return MailNotice(
      id: idFor(m.id),
      title: code == null ? sender : 'Code $code from $sender',
      body: subject == null || subject.isEmpty ? '(no subject)' : subject,
      preview: previews ? _preview(m.snippet) : null,
      messageId: m.id,
      code: code,
      receivedAt: m.receivedAt,
    );
  }

  static MailNotice _summary(Account account, NewMail mail) {
    final newest = mail.messages.reversed.toList();
    final lines = [
      for (final m in newest.take(summaryLines))
        '${senderName(m)} — ${_subjectOf(m)}',
    ];
    final more = mail.total - lines.length;
    return MailNotice(
      id: summaryId(account.id),
      title: '${mail.total} new emails',
      body: _joinSenders(_senders(newest)),
      lines: lines,
      more: more > 0 ? 'and $more more' : null,
      isSummary: true,
    );
  }

  /// The sender's name, or address.
  static String senderName(StoredMessage m) {
    final from = m.from;
    final name = from?.displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return from?.address ?? 'Unknown sender';
  }

  static String _subjectOf(StoredMessage m) {
    final code = m.shownCode;
    if (code != null) return 'Code $code';
    final subject = m.subject?.trim();
    return subject == null || subject.isEmpty ? '(no subject)' : subject;
  }

  /// Distinct sender names, in the given order.
  static List<String> _senders(Iterable<StoredMessage> messages) =>
      {for (final m in messages) senderName(m)}.toList();

  /// "Alice, Bob, Carol, …"
  static String _joinSenders(List<String> senders) => senders.length <= 3
      ? senders.join(', ')
      : '${senders.take(3).join(', ')}, …';

  static String? _preview(String? snippet) {
    final text = snippet?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == null || text.isEmpty) return null;
    if (text.length <= previewLength) return text;
    final cut = text.substring(0, previewLength);
    final space = cut.lastIndexOf(' ');
    return '${(space > previewLength * 0.6 ? cut.substring(0, space) : cut).trimRight()}…';
  }

  /// A message's notification id: below the reminders' range
  /// (0x20000000 and up) and the summaries' (0x40000000 and up).
  static int idFor(int messageId) => messageId & 0x1FFFFFFF;

  /// The summary (or "and N more", or locked) notification of an account.
  static int summaryId(int accountId) => 0x40000000 | (accountId & 0xFFFFFF);

  /// The message id in a tapped notification's payload.
  static int? messageIdOf(String? payload) {
    if (payload == null || !payload.startsWith('message:')) return null;
    return int.tryParse(payload.substring('message:'.length));
  }
}

/// The Copy code button: copies the code without opening the app, and
/// changes nothing in the mail (nothing is marked read).
///
/// The code travels in the button's action id (`copy:<message id>:<code>`),
/// so the button works without opening the encrypted database (on Android
/// it runs in a short background engine). Windows hands the id back as the
/// payload too.
abstract final class CopyCodeAction {
  static const label = 'Copy code';

  static String actionId(int messageId, String code) => 'copy:$messageId:$code';

  /// The message and code of a Copy code button, or null for anything else.
  static ({int messageId, String code})? parse(String? id) {
    if (id == null || !id.startsWith('copy:')) return null;
    final rest = id.substring('copy:'.length);
    final colon = rest.indexOf(':');
    if (colon <= 0) return null;
    final messageId = int.tryParse(rest.substring(0, colon));
    final code = rest.substring(colon + 1);
    if (messageId == null || code.isEmpty) return null;
    return (messageId: messageId, code: code);
  }

  /// Handles a notification response if it is a Copy code button: copies
  /// the code with [copy] and removes that message's notification with
  /// [dismiss] (Android already removed it). Returns whether it was one.
  static Future<bool> handle(
    String? actionId,
    String? payload, {
    required Future<void> Function(String code) copy,
    Future<void> Function(int notificationId)? dismiss,
  }) async {
    final action = parse(actionId) ?? parse(payload);
    if (action == null) return false;
    await copy(action.code);
    await dismiss?.call(MailNotices.idFor(action.messageId));
    return true;
  }
}
