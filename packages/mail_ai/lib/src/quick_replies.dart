// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'ai_errors.dart';
import 'ai_types.dart';
import 'mail_prompt.dart';

/// "Suggest replies": up to [max] short answers to one personal email,
/// as structured output. A suggestion is only text the user can pick to
/// start a reply, which they then edit and send themselves.
///
/// What the model answers is data too: [validate] keeps at most [max]
/// plain, single-line strings of at most [maxLength] characters, and
/// drops anything with a link, or that asks for or gives a password.
abstract final class QuickReplies {
  static const max = 3;
  static const maxLength = 200;

  /// The answer's shape. Lengths and counts are checked in [validate]
  /// rather than here, since not every provider's structured output
  /// accepts limits.
  static const schema = AiJsonSchema(
    name: 'quick_replies',
    schema: {
      'type': 'object',
      'properties': {
        'replies': {
          'type': 'array',
          'description':
              'At most 3 short replies, each at most 200 characters; empty '
              'when the email needs no reply.',
          'items': {'type': 'string'},
        },
      },
      'required': ['replies'],
      'additionalProperties': false,
    },
  );

  static const task =
      'You suggest short replies the person reading an email could send '
      'back to its sender. Suggest at most 3, each one or two short '
      'sentences of plain text, at most 200 characters, in the language '
      'of the email, and different from each other (for example: yes, '
      'no, or another time). No greeting and no sign-off: the app adds '
      'them. Never include links, email addresses, passwords, codes or '
      'other personal details, and never promise money. If the email '
      'needs no reply, answer with an empty list. Answer only with the '
      'JSON object asked for.';

  /// The request for [mail].
  static AiRequest request({
    required String model,
    required PromptMail mail,
    MailPrompt? prompt,
  }) => (prompt ?? MailPrompt()).request(
    model: model,
    task: task,
    mails: [mail],
    request: 'Suggest up to 3 short replies to email 1.',
    maxOutputTokens: 600,
    jsonSchema: schema,
    effort: AiEffort.low,
  );

  /// The suggestions in [response]. Throws [AiException] with
  /// [AiProblem.badResponse] when it isn't the JSON object asked for.
  static List<String> parse(AiResponse response) {
    final json = response.json;
    if (json == null || json['replies'] is! List) {
      throw const AiException(
        AiProblem.badResponse,
        'the suggestions were not in the expected form',
      );
    }
    return validate(json['replies']! as List);
  }

  /// At most [max] distinct, harmless suggestions from [replies]: strings
  /// only, on one line, without invisible characters, at most
  /// [maxLength] characters, and nothing with a link or about passwords.
  static List<String> validate(List<Object?> replies) {
    final out = <String>[];
    final seen = <String>{};
    for (final reply in replies) {
      if (out.length == max) break;
      if (reply is! String) continue;
      final text = MailPrompt.neutralise(reply)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isEmpty || text.length > maxLength) continue;
      if (_link.hasMatch(text) || _secret.hasMatch(text)) continue;
      if (!seen.add(text.toLowerCase())) continue;
      out.add(text);
    }
    return out;
  }

  /// A web address or something that becomes one.
  static final _link = RegExp(
    r'(https?:|ftp:|www\.|[a-z0-9-]+\.(com|net|org|io|ru|cn|xyz|ly|me|app)\b)',
    caseSensitive: false,
  );

  /// Passwords and sign-in codes, in the languages the app guesses.
  static final _secret = RegExp(
    r'(password|passcode|passwort|kennwort|mot de passe|contrase[ñn]a|'
    r'senha|wachtwoord|lösenord|hasło|PIN code|one-time code|2fa)',
    caseSensitive: false,
  );
}
