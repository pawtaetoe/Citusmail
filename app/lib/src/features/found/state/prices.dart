// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';

/// Prices and cadences in words.
abstract final class Prices {
  static const _symbols = {
    'SGD': r'S$',
    'USD': r'US$',
    'AUD': r'A$',
    'CAD': r'C$',
    'HKD': r'HK$',
    'NZD': r'NZ$',
    'EUR': '€',
    'GBP': '£',
    'JPY': '¥',
    'INR': '₹',
    'KRW': '₩',
    'MYR': 'RM',
    r'$': r'$',
  };

  /// "S$17.98", "¥1200", "CHF 9.90".
  static String format(Money money) {
    final noCents = money.currency == 'JPY' || money.currency == 'KRW';
    final units = money.minor ~/ 100;
    final cents = (money.minor % 100).toString().padLeft(2, '0');
    final grouped = units.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    final number = noCents ? grouped : '$grouped.$cents';
    final symbol = _symbols[money.currency];
    return symbol == null ? '${money.currency} $number' : '$symbol$number';
  }

  static String cadence(Cadence? cadence) => switch (cadence) {
    Cadence.weekly => 'Weekly',
    Cadence.monthly => 'Monthly',
    Cadence.quarterly => 'Every 3 months',
    Cadence.yearly => 'Yearly',
    null => 'How often unknown',
  };
}
