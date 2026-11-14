// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_ai/mail_ai.dart';
import 'package:test/test.dart';

void main() {
  const samples = {
    'en':
        'Hi Alice, thanks for sending the photos. Could we move the call to '
        'Thursday? Let me know what works for you. Best regards, Tom',
    'de':
        'Hallo Alice, vielen Dank für die Fotos! Können wir das Treffen auf '
        'Donnerstag verschieben? Sag mir bitte, ob das für dich passt. '
        'Liebe Grüße, Thomas',
    'fr':
        'Bonjour Alice, merci pour les photos. Est-ce que nous pouvons '
        'déplacer la réunion à jeudi ? Dis-moi si cela te convient. '
        'Cordialement, Thomas',
    'es':
        'Hola Alice, gracias por las fotos. ¿Podemos mover la reunión al '
        'jueves? Dime si te viene bien. Saludos, Tomás',
    'it':
        'Ciao Alice, grazie per le foto. Possiamo spostare la riunione a '
        'giovedì? Fammi sapere se ti va bene. Cordiali saluti, Tommaso',
    'nl':
        'Hallo Alice, bedankt voor de foto\'s. Kunnen we de afspraak naar '
        'donderdag verplaatsen? Laat me weten of dat voor jou goed is. '
        'Groeten, Thomas',
    'pt':
        'Olá Alice, obrigado pelas fotos. Podemos mudar a reunião para '
        'quinta-feira? Diga-me se isso funciona para você. Abraço, Tomás',
    'sv':
        'Hej Alice, tack för bilderna. Kan vi flytta mötet till torsdag? '
        'Säg till om det passar dig. Vänliga hälsningar, Tomas',
    'pl':
        'Dzień dobry Alice, dziękuję za zdjęcia. Czy możemy przenieść '
        'spotkanie na czwartek? Daj mi znać, czy to ci pasuje. Pozdrawiam',
    'ru':
        'Привет, Алиса! Спасибо за фотографии. Можем ли мы перенести '
        'встречу на четверг? Дай знать, подходит ли тебе это.',
    'uk':
        'Привіт, Алісо! Дякую за фотографії. Чи можемо ми перенести '
        'зустріч на четвер? Дай знати, чи це тобі підходить.',
    'ja': 'アリスさん、写真をありがとうございます。会議を木曜日に変更できますか？ご都合を教えてください。',
    'zh': '爱丽丝你好，谢谢你的照片。我们可以把会议改到星期四吗？请告诉我你是否方便。',
    'ko': '앨리스 씨, 사진 고마워요. 회의를 목요일로 옮길 수 있을까요? 괜찮은지 알려주세요.',
    'el':
        'Γεια σου Αλίκη, ευχαριστώ για τις φωτογραφίες. Μπορούμε να '
        'μεταφέρουμε τη συνάντηση την Πέμπτη;',
    'ar': 'مرحبا أليس، شكرا على الصور. هل يمكننا نقل الاجتماع إلى يوم الخميس؟',
  };

  for (final MapEntry(key: language, value: text) in samples.entries) {
    test('a personal email in ${LanguageGuess.name(language)}', () {
      expect(LanguageGuess.of(text), language);
    });
  }

  test('too short, or not sentences: no guess', () {
    expect(LanguageGuess.of('OK!'), isNull);
    expect(LanguageGuess.of('Danke'), isNull);
    expect(LanguageGuess.of('Your code: 482913'), isNull);
    expect(
      LanguageGuess.of('Order 4471 · SKU 99-ZX · Qty 2 · Total 84.20 EUR'),
      isNull,
    );
  });

  test('an English email quoting a few foreign words stays English', () {
    expect(
      LanguageGuess.of(
        'Hi team, the client wrote "vielen Dank" and "à bientôt" at the end '
        'of the call, which was nice. We will send them the contract '
        'tomorrow, and I will let you know when it is signed.',
      ),
      'en',
    );
  });

  test('foreign only when not in one of the user\'s languages', () {
    expect(LanguageGuess.isForeign(samples['de']!, ['en-GB']), isTrue);
    expect(LanguageGuess.isForeign(samples['de']!, ['en', 'de-AT']), isFalse);
    expect(LanguageGuess.isForeign(samples['en']!, ['en_US']), isFalse);
    expect(
      LanguageGuess.isForeign('Thanks!', ['de']),
      isFalse,
      reason: 'unsure is not foreign',
    );
  });

  test('language names, and codes with a region', () {
    expect(LanguageGuess.name('de'), 'German');
    expect(LanguageGuess.name('pt-BR'), 'Portuguese');
    expect(LanguageGuess.name('nb'), 'Norwegian');
    expect(LanguageGuess.name('xx'), isNull);
    expect(LanguageGuess.baseCode('zh_Hant_TW'), 'zh');
  });
}
