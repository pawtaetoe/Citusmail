// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mail_ai/mail_ai.dart';

import '../mail/ai_reader_mail.dart';
import '../mail/ai_translations.dart';
import '../mail/mail_controller.dart';
import 'ai_confirm.dart';
import 'app_icons.dart';
import 'citusmail_theme.dart';

/// "Translate" in the reader (an AI feature, off by default): the toolbar
/// action, the bar under the header that offers it and toggles between
/// the translation and the original, and the translated text in place of
/// the body.
abstract final class AiTranslate {
  /// Whether the reader offers Translate at all.
  static bool isOn(MailController c) =>
      c.services.ai.isOn(AiFeatures.translate.id);

  static MailTranslations translations(MailController c) =>
      MailTranslations.of(c.services.ai);

  /// The languages of this device, as codes, the first one preferred.
  static List<String> userLanguages() {
    final locales = WidgetsBinding.instance.platformDispatcher.locales;
    return [for (final l in locales) l.languageCode];
  }

  /// The language translations go into: the device's first language.
  static String target() => userLanguages().firstOrNull ?? 'en';

  /// [r]'s language as far as the device can tell (null when unsure).
  static String? languageOf(MailController c, ReaderReady r) =>
      translations(c).guess(
        r.message.id,
        () =>
            '${r.message.subject ?? ''}\n'
            '${AiReaderMail.text(r.view.body, quotes: false)}',
      );

  /// Translates [r] into the device's language, or shows the
  /// translation already made.
  static void run(BuildContext context, MailController c, ReaderReady r) =>
      unawaited(
        translations(c).translate(
          r.message.id,
          AiReaderMail.of(r),
          target(),
          confirm: (provider) => context.mounted
              ? AiConfirm.ask(context, provider)
              : Future.value(false),
        ),
      );
}

/// Under the header (and under any warning about the message): offers a
/// translation when the email seems to be in another language than the
/// device's, shows one coming in, and switches between it and the
/// original.
final class TranslateBar extends StatelessWidget {
  const TranslateBar({
    super.key,
    required this.controller,
    required this.reader,
  });

  final MailController controller;
  final ReaderReady reader;

  @override
  Widget build(BuildContext context) {
    final translations = AiTranslate.translations(controller);
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.services.ai.changes,
        translations,
      ]),
      builder: (context, _) {
        if (!AiTranslate.isOn(controller)) return const SizedBox.shrink();
        final id = reader.message.id;
        final target = AiTranslate.target();
        final into = MailTranslation.languageName(target);
        final from = AiTranslate.languageOf(controller, reader);
        final fromName = from == null
            ? null
            : MailTranslation.languageName(from);
        final foreign =
            from != null &&
            !AiTranslate.userLanguages()
                .map(LanguageGuess.baseCode)
                .contains(from);
        void translate() => AiTranslate.run(context, controller, reader);
        final t = translations.shown(id);
        if (t == null) {
          if (translations.find(id, target) case final made?
              when made.status == TranslationStatus.done) {
            return _Bar(
              text: 'Translated into $into.',
              actions: [
                TextButton(
                  onPressed: translate,
                  child: const Text('Show translation'),
                ),
              ],
            );
          }
          if (!foreign || translations.notNow(id)) {
            return const SizedBox.shrink();
          }
          return _Bar(
            text: 'This email seems to be in $fromName.',
            actions: [
              TextButton(
                key: const ValueKey('translate-offer'),
                onPressed: translate,
                child: Text('Translate to $into'),
              ),
              IconButton(
                tooltip: 'Not now',
                icon: const Icon(AppIcons.close, size: 18),
                onPressed: () => translations.dismiss(id),
              ),
            ],
          );
        }
        return switch (t.status) {
          TranslationStatus.working => _Bar(
            text: 'Translating into $into with ${t.recipient}…',
            busy: true,
            actions: [
              TextButton(
                onPressed: () => translations.stop(id),
                child: const Text('Stop'),
              ),
            ],
          ),
          TranslationStatus.done => _Bar(
            text: [
              fromName == null
                  ? 'Translated into $into by ${t.recipient}.'
                  : 'Translated from $fromName into $into by ${t.recipient}.',
              if (t.cutOff)
                'The end is missing: the email is too long to translate whole.',
            ].join(' '),
            note: AiSentNote(recipient: t.recipient),
            actions: [
              TextButton(
                onPressed: () => translations.showOriginal(id),
                child: const Text('Show original'),
              ),
            ],
          ),
          TranslationStatus.failed => _Bar(
            text: t.problem ?? 'Couldn\'t translate this email.',
            actions: [
              TextButton(onPressed: translate, child: const Text('Try again')),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(AppIcons.close, size: 18),
                onPressed: () => translations.showOriginal(id),
              ),
            ],
          ),
        };
      },
    );
  }
}

final class _Bar extends StatelessWidget {
  const _Bar({
    required this.text,
    required this.actions,
    this.note,
    this.busy = false,
  });

  final String text;
  final List<Widget> actions;
  final Widget? note;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('translate-bar'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(CitusmailTheme.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        AppIcons.translate,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        text,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: actions),
            ],
          ),
          if (note case final note?)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, right: 8),
              child: note,
            ),
        ],
      ),
    );
  }
}

/// The body: the translation when the email shows one, else [original].
/// The translation is plain text: web addresses in it stay text and
/// never become links, whatever the model wrote.
final class TranslatedBody extends StatelessWidget {
  const TranslatedBody({
    super.key,
    required this.controller,
    required this.reader,
    required this.padding,
    required this.original,
  });

  final MailController controller;
  final ReaderState reader;
  final EdgeInsets padding;

  /// The body as written (a sliver).
  final Widget original;

  @override
  Widget build(BuildContext context) {
    final message = reader.message;
    if (reader is! ReaderReady || message == null) return original;
    final translations = AiTranslate.translations(controller);
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.services.ai.changes,
        translations,
      ]),
      builder: (context, _) {
        final t = AiTranslate.isOn(controller)
            ? translations.shown(message.id)
            : null;
        if (t == null || t.status == TranslationStatus.failed) return original;
        final theme = Theme.of(context);
        final text = t.text;
        return SliverPadding(
          padding: padding,
          sliver: SliverToBoxAdapter(
            child: text.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Text(
                    text,
                    key: const ValueKey('translation'),
                    style: theme.textTheme.bodyLarge!.copyWith(height: 1.45),
                  ),
          ),
        );
      },
    );
  }
}
