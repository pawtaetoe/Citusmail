// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';

import '../mail/deliveries_model.dart' show openReturnWindows;
import '../mail/subscriptions_model.dart';
import '../ui/subscriptions_page.dart' show Prices;
import 'app_settings.dart';

/// What the user did with reminders, and which were notified, kept in the
/// settings store (so the background job on Android sees the same).
final class ReminderState {
  ReminderState(this._store);

  final MailStore _store;

  static const _dismissed = 'reminders.dismissed';
  static const _notified = 'reminders.notified';
  static const _lastCheck = 'reminders.lastCheck';

  /// Entries are kept this long after their date.
  static const _keep = Duration(days: 60);

  /// Reminders marked "Done" or "Not needed" (their [Reminder.key]).
  Set<String> get dismissed => _read(_dismissed);

  void dismiss(String key) => _write(_dismissed, {...dismissed, key});

  void undismiss(String key) => _write(_dismissed, {...dismissed}..remove(key));

  /// The notifications posted: `key@stage`.
  Set<String> get notified => _read(_notified);

  void markNotified(Iterable<String> entries) =>
      _write(_notified, {...notified, ...entries});

  /// When reminders were last checked for notifications.
  DateTime? get lastCheck {
    final ms = int.tryParse(_store.settings.read(_lastCheck) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set lastCheck(DateTime? at) => _store.settings.write(
    _lastCheck,
    at == null ? '' : '${at.millisecondsSinceEpoch}',
  );

  Set<String> _read(String key) => {
    ...?_store.settings.read(key)?.split(',').where((s) => s.isNotEmpty),
  };

  /// Writes [entries], dropping those whose date is long past.
  void _write(String key, Set<String> entries) {
    final since = DateTime.now().toUtc().subtract(_keep);
    final kept = [
      for (final e in entries)
        if (_dateOf(e)?.isBefore(since) != true) e,
    ];
    _store.settings.write(key, kept.join(','));
  }

  /// The date at the end of a key ("billDue:x.com:2026-11-15@soon").
  static DateTime? _dateOf(String entry) {
    final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})(?:@\w+)?$').firstMatch(entry);
    if (m == null) return null;
    return DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
}

/// Reminders in words, for the page and notifications.
abstract final class ReminderWords {
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

  /// "Fri, 15 Nov".
  static String date(DateTime day) =>
      '${_weekdays[day.weekday - 1]}, ${day.day} ${_months[day.month - 1]}';

  /// "today", "tomorrow", "in 3 days", "yesterday", "2 days ago".
  static String when(int days) => switch (days) {
    0 => 'today',
    1 => 'tomorrow',
    -1 => 'yesterday',
    < 0 => '${-days} days ago',
    _ => 'in $days days',
  };

  /// "S$59.88 a year".
  static String price(Money money, Cadence? cadence) =>
      '${Prices.format(money)}${switch (cadence) {
        Cadence.weekly => ' a week',
        Cadence.monthly => ' a month',
        Cadence.quarterly => ' every 3 months',
        Cadence.yearly => ' a year',
        null => '',
      }}';

  /// What the page says: "Due Fri, 15 Nov", "Free trial ends Thu, 12 Nov,
  /// then S$59.88 a year", "Renews Tue, 10 Nov".
  static String detail(Reminder r, DateTime now) {
    final on = date(r.date);
    final days = r.daysFrom(now);
    return switch (r.kind) {
      ReminderKind.billDue when days < 0 => 'Was due $on',
      ReminderKind.billDue => 'Due $on',
      ReminderKind.trialEnds => [
        'Free trial ends $on',
        if (r.amount case final a?) 'then ${price(a, r.cadence)}',
      ].join(', '),
      ReminderKind.renewal => 'Renews $on',
      ReminderKind.returnBy => 'Return by $on',
    };
  }

  /// What a notification says: "MyRepublic bill of $32.99 is due in 3
  /// days", "Your pandapro free trial ends tomorrow, then S$59.88 a year",
  /// "Spotify renews in 3 days (S$11.98)".
  static String notification(Reminder r, DateTime now) {
    final when = ReminderWords.when(r.daysFrom(now));
    final amount = r.amount;
    return switch (r.kind) {
      ReminderKind.billDue when amount != null =>
        '${r.name} bill of ${Prices.format(amount)} is due $when',
      ReminderKind.billDue => '${r.name} bill is due $when',
      ReminderKind.trialEnds when amount != null =>
        'Your ${r.name} free trial ends $when, then '
            '${price(amount, r.cadence)}',
      ReminderKind.trialEnds => 'Your ${r.name} free trial ends $when',
      ReminderKind.renewal when amount != null =>
        '${r.name} renews $when (${Prices.format(amount)})',
      ReminderKind.renewal => '${r.name} renews $when',
      ReminderKind.returnBy when when == 'today' =>
        'Today is the last day to return your ${r.name} order',
      ReminderKind.returnBy =>
        'Your ${r.name} order can be returned until ${date(r.date)} '
            '($when)',
    };
  }

  /// The notification's title.
  static String title(Reminder r) => switch (r.kind) {
    ReminderKind.billDue => 'Bill due',
    ReminderKind.trialEnds => 'Free trial ending',
    ReminderKind.renewal => 'Renewal coming up',
    ReminderKind.returnBy => 'Return window closing',
  };
}

/// One reminder notification to post.
final class ReminderNotice {
  const ReminderNotice(this.reminder, this.title, this.text);

  final Reminder reminder;
  final String title;
  final String text;

  /// A notification id of its own, stable across runs, apart from new-mail
  /// ones (0x20000000 to 0x2FFFFFFF).
  int get id {
    var hash = 0x811C9DC5;
    for (final unit in reminder.key.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return 0x20000000 | (hash & 0x0FFFFFFF);
  }
}

/// After a sync: notifications for bills due, free trials ending,
/// renewals coming up and return windows closing (orders not marked
/// "Returned" or "Keeping it" on the Deliveries page), from the mail on
/// the device. Each reminder is
/// notified at most once per stage (three days before, and on the day for
/// bills), never once dismissed, only with the notification settings on,
/// in the daytime, and at most twice a day.
abstract final class ReminderCheck {
  /// At most this often.
  static const every = Duration(hours: 12);

  /// Only between these hours (local time), not at night.
  static const fromHour = 8;
  static const untilHour = 21;

  /// Notified this many days before.
  static const soonDays = 3;

  static bool _running = false;

  /// Checks, and hands the notifications to make to [post]. Returns them
  /// (none when it is not time to check).
  static Future<List<ReminderNotice>> run(
    MailStore store,
    Future<void> Function(List<ReminderNotice> notices) post, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final settings = AppSettings(store);
    if (!settings.notifications || !settings.reminders) return const [];
    if (at.hour < fromHour || at.hour > untilHour) return const [];
    final state = ReminderState(store);
    if (state.lastCheck case final last?
        when at.difference(last) < every && !at.isBefore(last)) {
      return const [];
    }
    if (_running) return const [];
    _running = true;
    try {
      state.lastCheck = at;
      final mail = await loadSubscriptionMail(store, at);
      final hidden = hiddenSubscriptions(store);
      final found = SubscriptionFinder.find(mail.emails, now: at);
      final reminders = Reminders.find(
        mail.emails,
        subscriptions: found,
        now: at,
        monthlyRenewals: settings.monthlyRenewals,
        hidden: {
          ...hidden,
          ...await learnedNotSubscriptions(store, mail, found, hidden),
        },
      );
      final returns = await openReturnWindows(store, at);
      final notices = due(
        [
          ...reminders,
          for (final w in returns)
            Reminder(
              kind: ReminderKind.returnBy,
              company: w.shop,
              name: w.shopName,
              date: w.deadline,
              messageId: w.messageId,
            ),
        ],
        now: at,
        dismissed: state.dismissed,
        notified: state.notified,
      );
      if (notices.isEmpty) return const [];
      state.markNotified([
        for (final n in notices)
          for (final stage in _stages(n.reminder, at))
            '${n.reminder.key}@$stage',
      ]);
      await post(notices);
      return notices;
    } finally {
      _running = false;
    }
  }

  /// The notifications [reminders] call for [now]: one per stage reached
  /// and not yet [notified], none for [dismissed] ones.
  static List<ReminderNotice> due(
    List<Reminder> reminders, {
    required DateTime now,
    Set<String> dismissed = const {},
    Set<String> notified = const {},
  }) => [
    for (final r in reminders)
      if (!dismissed.contains(r.key) &&
          _stages(r, now).isNotEmpty &&
          !notified.contains('${r.key}@${_stages(r, now).first}'))
        ReminderNotice(
          r,
          ReminderWords.title(r),
          ReminderWords.notification(r, now),
        ),
  ];

  /// The stages [r] has reached, the current one first: `today` (a bill
  /// due today) and `soon` (within [soonDays]).
  static List<String> _stages(Reminder r, DateTime now) {
    final days = r.daysFrom(now);
    if (days < 0 || days > soonDays) return const [];
    if (r.kind == ReminderKind.billDue && days == 0) {
      return const ['today', 'soon'];
    }
    return const ['soon'];
  }
}
