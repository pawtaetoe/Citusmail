// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_ai/mail_ai.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_trust/mail_trust.dart';
import 'package:mail_view/mail_view.dart';

import 'mail_controller.dart';

/// The email open in the reader, as the reader's AI helpers (Translate,
/// Quick replies) send it: its sender, subject and text, nothing else.
abstract final class AiReaderMail {
  /// [r]'s sender, subject and text. Each link's address is written out
  /// after its words ("the form (https://...)"), so a translation shows
  /// where links go, as plain text.
  static PromptMail of(ReaderReady r) => PromptMail(
    from: switch (r.message.from) {
      final from? => _display(from),
      null => '(no sender)',
    },
    subject: r.message.subject,
    body: text(r.view.body),
  );

  /// The text of [body], with link addresses written out; quoted earlier
  /// messages are left out when [quotes] is false (to guess the language
  /// of what was written, not of what is quoted).
  static String text(RichDocument body, {bool quotes = true}) {
    final out = StringBuffer();
    void inlines(List<Inline> list) {
      for (final inline in list) {
        switch (inline) {
          case TextRun(:final text, :final link):
            out.write(text);
            if (link != null) {
              final address = link.scheme == 'mailto' ? link.path : '$link';
              if (address.isNotEmpty && !text.contains(address)) {
                out.write(' ($address)');
              }
            }
          case LineBreak():
            out.write('\n');
          case ImageInline(:final alt) || RemoteImageInline(:final alt):
            if (alt.isNotEmpty) out.write(alt);
        }
      }
      out.write('\n');
    }

    void blocks(List<Block> list) {
      for (final block in list) {
        switch (block) {
          case ParagraphBlock(inlines: final i) ||
              HeadingBlock(inlines: final i):
            inlines(i);
            out.write('\n');
          case QuoteBlock(:final children):
            if (quotes) blocks(children);
          case ListBlock(:final items):
            for (final item in items) {
              blocks(item);
            }
          case PreformattedBlock(:final text):
            out
              ..write(text)
              ..write('\n\n');
          case TableBlock(:final rows):
            for (final row in rows) {
              for (final cell in row) {
                blocks(cell.blocks);
              }
            }
          case RuleBlock():
            out.write('\n');
        }
      }
    }

    blocks(body.blocks);
    return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Whether [r] is personal mail a short reply suits: General mail from
  /// someone else (not a newsletter, a notification, a code or a mailing
  /// list), not in Junk, not an invitation, and not a suspected scam.
  static bool personal(MailController c, ReaderReady r) {
    final m = r.message;
    return m.category == MessageCategory.general &&
        m.listId == null &&
        m.shownCode == null &&
        r.view.invite == null &&
        r.trust.level != TrustLevel.danger &&
        !r.unsubscribe.available &&
        !c.isInJunk(m) &&
        c.canBlock(m);
  }

  static String _display(MailAddress a) {
    final name = a.displayName?.trim();
    return name == null || name.isEmpty ? a.address : '$name <${a.address}>';
  }
}
