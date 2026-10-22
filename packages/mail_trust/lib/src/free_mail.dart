// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Mail services where anyone can get an address. Blocking a whole domain
/// makes no sense for these: it would block millions of people.
abstract final class FreeMail {
  static const providers = {
    '126.com',
    '163.com',
    'aol.com',
    'fastmail.com',
    'fastmail.fm',
    'gmail.com',
    'gmx.at',
    'gmx.ch',
    'gmx.com',
    'gmx.de',
    'gmx.net',
    'googlemail.com',
    'hey.com',
    'hotmail.co.uk',
    'hotmail.com',
    'hotmail.de',
    'hotmail.fr',
    'icloud.com',
    'live.com',
    'mac.com',
    'mail.com',
    'mail.ru',
    'me.com',
    'msn.com',
    'naver.com',
    'outlook.com',
    'outlook.de',
    'pm.me',
    'proton.me',
    'protonmail.com',
    'qq.com',
    'rambler.ru',
    'tuta.io',
    'tutanota.com',
    'web.de',
    'yahoo.co.jp',
    'yahoo.co.uk',
    'yahoo.com',
    'yahoo.de',
    'yahoo.fr',
    'yandex.com',
    'yandex.ru',
    'ymail.com',
    'zoho.com',
    'zohomail.com',
  };

  /// Whether [registrable] (a registrable domain) is a free mail service.
  static bool isProvider(String registrable) =>
      providers.contains(registrable.toLowerCase());
}
