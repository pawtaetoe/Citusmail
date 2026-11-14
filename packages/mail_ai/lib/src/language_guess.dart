// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// A guess, on the device, at the language an email is written in: by
/// its script (Cyrillic, Greek, Arabic, Chinese, Japanese...) or, for
/// the Latin script, by its most common little words. Nothing is sent
/// anywhere to guess. It answers only when it is fairly sure, so that a
/// "Translate" offer shows up on mail that needs one, not on mail that
/// merely quotes a few foreign words.
abstract final class LanguageGuess {
  /// The text looked at: the start of an email says enough.
  static const maxChars = 2000;

  /// Fewer words than this and the guess is left alone (a short "OK!").
  static const minWords = 6;

  /// The language of [text] as an ISO 639-1 code (`de`, `fr`, `ja`), or
  /// null when unsure.
  static String? of(String text) {
    final sample = text.length > maxChars ? text.substring(0, maxChars) : text;
    return _byScript(sample) ?? _byWords(sample);
  }

  /// Whether [text] is in a language other than [languages] (codes such
  /// as `en` or `pt-BR`), as far as [of] can tell.
  static bool isForeign(String text, Iterable<String> languages) {
    final guess = of(text);
    if (guess == null) return false;
    return !languages.map(baseCode).contains(guess);
  }

  /// `pt-BR` and `pt_BR` → `pt`; Norwegian Bokmål and Nynorsk → `no`.
  static String baseCode(String code) {
    final base = code.split(RegExp('[-_]')).first.toLowerCase();
    return switch (base) {
      'nb' || 'nn' => 'no',
      _ => base,
    };
  }

  /// The language's English name ("German"), or null if unknown.
  static String? name(String code) => _names[baseCode(code)];

  static const _names = {
    'ar': 'Arabic',
    'bg': 'Bulgarian',
    'ca': 'Catalan',
    'cs': 'Czech',
    'da': 'Danish',
    'de': 'German',
    'el': 'Greek',
    'en': 'English',
    'es': 'Spanish',
    'et': 'Estonian',
    'fa': 'Persian',
    'fi': 'Finnish',
    'fr': 'French',
    'he': 'Hebrew',
    'hi': 'Hindi',
    'hr': 'Croatian',
    'hu': 'Hungarian',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'lt': 'Lithuanian',
    'lv': 'Latvian',
    'ms': 'Malay',
    'nl': 'Dutch',
    'no': 'Norwegian',
    'pl': 'Polish',
    'pt': 'Portuguese',
    'ro': 'Romanian',
    'ru': 'Russian',
    'sk': 'Slovak',
    'sl': 'Slovenian',
    'sr': 'Serbian',
    'sv': 'Swedish',
    'th': 'Thai',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'vi': 'Vietnamese',
    'zh': 'Chinese',
  };

  // Scripts that name their language well enough on their own.
  static final _hangul = RegExp(r'[가-힯ᄀ-ᇿ]');
  static final _kana = RegExp(r'[぀-ヿ]');
  static final _han = RegExp(r'[一-鿿]');
  static final _cyrillic = RegExp(r'[Ѐ-ӿ]');
  static final _ukrainian = RegExp('[іїєґІЇЄҐ]');
  static final _greek = RegExp(r'[Ͱ-Ͽ]');
  static final _arabic = RegExp(r'[؀-ۿ]');
  static final _persian = RegExp('[پچژگ]');
  static final _hebrew = RegExp(r'[֐-׿]');
  static final _thai = RegExp(r'[฀-๿]');
  static final _devanagari = RegExp(r'[ऀ-ॿ]');
  static final _latin = RegExp(r'[A-Za-zÀ-ɏ]');

  static String? _byScript(String text) {
    int count(RegExp r) => r.allMatches(text).length;
    final latin = count(_latin);
    final scripts = <String, int>{
      'ko': count(_hangul),
      'ja': count(_kana),
      'zh': count(_han),
      'cyrillic': count(_cyrillic),
      'el': count(_greek),
      'arabic': count(_arabic),
      'he': count(_hebrew),
      'th': count(_thai),
      'hi': count(_devanagari),
    };
    // Japanese mixes kana with Chinese characters.
    if (scripts['ja']! > 0 && scripts['ja']! * 10 >= scripts['zh']!) {
      scripts['ja'] = scripts['ja']! + scripts['zh']!;
      scripts['zh'] = 0;
    }
    final (script, letters) = scripts.entries
        .map((e) => (e.key, e.value))
        .reduce((a, b) => b.$2 > a.$2 ? b : a);
    // Mostly this script: more of its letters than Latin ones (Chinese
    // and Japanese characters are words, so a few count for more).
    final weight = switch (script) {
      'zh' || 'ja' || 'ko' => 3,
      _ => 1,
    };
    if (letters < 10 || letters * weight < latin) return null;
    return switch (script) {
      'cyrillic' => _ukrainian.allMatches(text).length >= 2 ? 'uk' : 'ru',
      'arabic' => _persian.allMatches(text).length >= 2 ? 'fa' : 'ar',
      _ => script,
    };
  }

  /// The most common little words of the Latin-script languages guessed
  /// here: each says a lot about its language and little about others.
  static final _words = <String, Set<String>>{
    'en': _set(
      'the and you that for with this have are was not your will can '
      'from but what all about would there please thanks we is it of '
      'to be at if my our just let know hi hello regards they were '
      'which when could',
    ),
    'de': _set(
      'der die und das ist nicht ich sie ein eine zu mit den auf für '
      'sich auch dem des wir es bitte ihr ihre haben wird sind bei '
      'vielen dank gerne uns von oder aber noch wie hallo grüße gruß '
      'liebe lieber kannst können mir dir ihnen nach schon',
    ),
    'fr': _set(
      'le les et est pas vous une des pour dans qui sur avec nous je '
      'ce cette sont mais bonjour merci votre vos du au aux il elle '
      'ne plus tu ton ta cordialement avez être fait très bien peux '
      'pouvez mon notre',
    ),
    'es': _set(
      'el los las y es que en un una por para con no su al lo como '
      'más pero gracias hola usted nos este esta muy está sus del '
      'saludos puedes puede tengo tienes estoy también hay ya mañana '
      'si me te',
    ),
    'it': _set(
      'il di che e per un una non sono con del della è ciao grazie '
      'gli ho come anche questo questa alla nel sei mi ti saluti puoi '
      'può molto domani ci hai abbiamo cordiali buongiorno perché sì '
      'più tutto vorrei',
    ),
    'nl': _set(
      'de het een en van ik je niet dat is op te met voor zijn er '
      'maar ook wij we jij u bedankt groeten hoe naar dit heb wel kun '
      'kunt jullie hebben graag morgen hallo dank mijn onze als om '
      'nog wat zou',
    ),
    'pt': _set(
      'os as e de que não um uma para com por em do da dos das você '
      'obrigado obrigada olá mais mas como seu sua está muito são nos '
      'ao na no pode tenho também amanhã abraço atenciosamente estou '
      'isso eu',
    ),
    'sv': _set(
      'och att det som en på är av för med till den har inte jag du '
      'vi kan om ett men så eller hej tack hälsningar vänliga mvh '
      'imorgon också mig dig här nu ska',
    ),
    'pl': _set(
      'i w nie na się z że do to jest jak ale po czy tak dla od mnie '
      'pan pani dzień dobry dziękuję pozdrawiam jutro mogę możesz '
      'proszę też już bardzo jestem mam',
    ),
    'tr': _set(
      've bir bu için ile da de çok ne ama merhaba teşekkürler '
      'teşekkür ederim saygılarımla yarın mi mı var yok olarak sizin '
      'benim lütfen gibi daha şimdi evet hayır',
    ),
  };

  static Set<String> _set(String words) => words.split(' ').toSet();

  static final _wordPattern = RegExp(r'\p{L}+', unicode: true);

  static String? _byWords(String text) {
    final words = [
      for (final m in _wordPattern.allMatches(text.toLowerCase())) m[0]!,
    ];
    if (words.length < minWords) return null;
    final scores = <String, int>{
      for (final MapEntry(key: language, value: common) in _words.entries)
        language: words.where(common.contains).length,
    };
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final next = ranked[1].value;
    // Clearly ahead, and common words make up a good part of the text
    // (real sentences, not a list of names or a code).
    if (best.value < 3) return null;
    if (best.value * 5 < words.length) return null;
    if (best.value < next * 1.5) return null;
    return best.key;
  }
}
