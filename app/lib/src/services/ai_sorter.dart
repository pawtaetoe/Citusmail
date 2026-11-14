// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_ai/mail_ai.dart';
import 'package:mail_sort/mail_sort.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_view/mail_view.dart';

import 'ai_assistant.dart';
import 'app_settings.dart';
import 'auto_reader.dart' show BodyLoader;

/// What one [AiSorter.run] did.
typedef AiSortRun = ({int asked, int moved});

/// "Sorting backup" (AI assistant, off by default): new inbox mail the
/// sorting rules have no signal for ([AiSortCandidates]) gets a category
/// from the user's AI provider.
///
/// The rules stay first. For each such message, a short excerpt goes to
/// the provider through [MailPrompt] (as data, never instructions): the
/// sender, the subject, the first [excerptChars] characters of the text
/// and whether it has mailing-list headers. Never attachments, never other
/// mail. The answer must be one of the app's categories with a one-line
/// reason and whether it is verification mail ([AiSortAnswer]); anything
/// else is ignored, so an email can at most change its own section.
/// Verification mail goes to Codes, where the code is read from it.
///
/// Runs after a sync brings new mail (a few seconds later, never during
/// it), at most [perSync] messages each time, only for mail less than a
/// day old, and never twice for a message ([AiSortLog]). Off, without a
/// key, or before the user agreed to what is sent: nothing happens at
/// all. A problem (the monthly limit, a bad key, offline) ends the run
/// quietly; the next one tries again.
final class AiSorter {
  AiSorter(
    this._store,
    this._ai,
    this._load, {
    this.onSorted,
    this.delay = const Duration(seconds: 5),
    this.firstDelay = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _sorters[_ai] = this;
  }

  final MailStore _store;
  final AiAssistant _ai;
  final BodyLoader _load;
  final DateTime Function() _now;

  /// After a run moved mail (or the user put one back): the lists are
  /// read again.
  VoidCallback? onSorted;

  /// How long a request waits for more (several syncs end close
  /// together).
  final Duration delay;

  /// The first run after [start] (mail that came while the app was
  /// closed).
  final Duration firstDelay;

  static const featureId = 'sorting';

  /// How much of the text is sent.
  static const excerptChars = 1500;

  /// Bigger messages are not downloaded for it: the preview is used.
  static const maxDownload = 512 * 1024;

  static const perSyncKey = 'ai.sorting.perSync';
  static const defaultPerSync = 20;
  static const perSyncChoices = [5, 10, 20, 50];

  static final _sorters = Expando<AiSorter>();

  /// The sorter using [ai] (for its setting in Settings).
  static AiSorter? of(AiAssistant ai) => _sorters[ai];

  /// At most this many messages are asked about after each sync.
  int get perSync {
    final value = int.tryParse(_store.settings.read(perSyncKey) ?? '');
    return value != null && value > 0 ? value : defaultPerSync;
  }

  set perSync(int value) {
    _store.settings.write(perSyncKey, '${value.clamp(1, 200)}');
    _ai.changes.value++;
  }

  /// The last run's problem, said plainly (null when it went well).
  final problem = ValueNotifier<String?>(null);

  bool get isOn => _ai.isOn(featureId);

  Timer? _timer;
  StreamSubscription<SyncEvent>? _events;
  bool _running = false;
  bool _again = false;
  bool _started = false;
  bool _stopped = false;

  /// Sorts a little after now, after each sync that brings new mail, and
  /// when the feature is turned on.
  void start(Stream<SyncEvent> events) {
    _started = true;
    _stopped = false;
    _events ??= events.listen((event) {
      if (event is AccountSynced &&
          event.report.mailboxes.values.any((r) => r.added > 0)) {
        request();
      }
    });
    _ai.changes
      ..removeListener(_settingsChanged)
      ..addListener(_settingsChanged);
    request(after: firstDelay);
  }

  bool _wasOn = false;

  void _settingsChanged() {
    final on = isOn;
    if (on && !_wasOn) request();
    _wasOn = on;
  }

  /// A run soon. Nothing when the feature is off, or before [start].
  void request({Duration? after}) {
    _wasOn = isOn;
    if (!_started || _stopped || !isOn) return;
    if (_running) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(after ?? delay, () {
      _timer = null;
      unawaited(run());
    });
  }

  /// Stops (the app is closing); a request under way ends with it.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _ai.changes.removeListener(_settingsChanged);
    unawaited(_events?.cancel());
    _events = null;
  }

  /// One run in the Android background check (after the news is out),
  /// with its own connection: as after a sync in the app.
  static Future<AiSortRun> sortOnce(
    MailStore store,
    AiAssistant ai,
    BodyLoader load,
  ) => AiSorter(store, ai, load).run();

  /// One run now.
  Future<AiSortRun> run() async {
    const nothing = (asked: 0, moved: 0);
    if (_running || _stopped || !isOn) return nothing;
    _running = true;
    _again = false;
    var asked = 0;
    var moved = 0;
    try {
      final provider = await _ai.providerFor(featureId);
      // Off, no key, or the user has not agreed to what is sent.
      if (provider == null || provider.needsConfirmation) return nothing;
      final waiting = AiSortCandidates.find(
        _store,
        now: _now(),
        limit: perSync,
      );
      for (final message in waiting) {
        if (_stopped || !isOn) break;
        final (text, whole) = await _text(message);
        if (_stopped || !isOn) break;
        final AiResponse response;
        try {
          asked++;
          response = await provider.complete(
            requestFor(
              message,
              text,
              model: provider.model,
              headers: _store.messages.headers(message.id),
            ),
          );
        } on AiException catch (e) {
          if (_aboutThisMessage(e.problem)) {
            _log(message, AiSortOutcome.ignored, by: provider.recipient);
            continue;
          }
          // The limit, the key, the connection: stop quietly, try again
          // after the next sync.
          if (e.problem != AiProblem.cancelled) {
            problem.value = e.explain(provider.recipient);
          }
          return (asked: asked, moved: moved);
        }
        final answer = response.stopReason == AiStopReason.finished
            ? AiSortAnswer.parse(response.json)
            : null;
        if (answer == null) {
          _log(message, AiSortOutcome.ignored, by: provider.recipient);
          continue;
        }
        if (_apply(
          message,
          answer,
          text,
          whole: whole,
          by: provider.recipient,
        )) {
          moved++;
        }
      }
      problem.value = null;
    } on Object catch (e) {
      debugPrint('ai sort: ${e.runtimeType}');
    } finally {
      _running = false;
      if (moved > 0 && !_stopped) onSorted?.call();
      if (_again && !_stopped) request();
    }
    return (asked: asked, moved: moved);
  }

  /// Problems with this one message (the next is asked); every other
  /// problem ends the run.
  static bool _aboutThisMessage(AiProblem problem) => switch (problem) {
    AiProblem.refused ||
    AiProblem.contextTooLong ||
    AiProblem.badResponse => true,
    _ => false,
  };

  /// The message's text: from its body (downloaded now if it isn't on
  /// the device yet and isn't large; it stays unread), else its preview;
  /// and whether it is the whole text.
  Future<(String, bool)> _text(StoredMessage message) async {
    var raw = _store.messages.body(message.id);
    if (raw == null && message.size <= maxDownload) {
      try {
        await _load(message.id);
        raw = _store.messages.body(message.id);
      } on Object {
        raw = null;
      }
    }
    if (raw != null) {
      try {
        return (MessageView.parse(raw).body.plainText, true);
      } on Object {
        // Unreadable: the preview below.
      }
    }
    return (message.snippet ?? '', false);
  }

  /// [message]'s text if its body is on the device, else its preview.
  String? _storedText(StoredMessage message) {
    if (_store.messages.body(message.id) case final raw?) {
      try {
        return MessageView.parse(raw).body.plainText;
      } on Object {
        // Unreadable: the preview.
      }
    }
    return message.snippet;
  }

  /// What is asked about [message] (with [text], its whole text; only
  /// the beginning is sent).
  @visibleForTesting
  static AiRequest requestFor(
    StoredMessage message,
    String text, {
    required String model,
    Map<String, List<String>> headers = const {},
    MailPrompt? prompt,
  }) {
    final from = message.from;
    final list =
        message.listId != null ||
        headers.containsKey('list-id') ||
        headers.containsKey('list-unsubscribe');
    return (prompt ?? MailPrompt()).request(
      model: model,
      task: _task,
      mails: [
        PromptMail(
          from: from == null
              ? '(unknown sender)'
              : from.displayName == null || from.displayName!.isEmpty
              ? from.address
              : '${from.displayName} <${from.address}>',
          subject: message.subject,
          body: excerpt(text),
        ),
      ],
      request:
          'Sort the email above. It ${list ? 'has' : 'has no'} '
          'mailing-list headers. Only the beginning of its text is '
          'included.',
      jsonSchema: const AiJsonSchema(
        name: 'mail_category',
        schema: AiSortAnswer.schema,
      ),
      maxOutputTokens: 300,
      effort: AiEffort.low,
    );
  }

  /// The beginning of [text]: at most [excerptChars] characters, without
  /// long runs of blank lines.
  @visibleForTesting
  static String excerpt(String text) {
    final tidy = text
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return tidy.length <= excerptChars ? tidy : tidy.substring(0, excerptChars);
  }

  static const _task = '''
You sort one email for a mail app, because its rules could not place it. Choose the one category it belongs in:
- general: written by a person to the reader, or anything that needs the reader's attention and fits no other category.
- notifications: automatic messages from a service about the reader's account or activity, such as receipts, orders, shipping, bills, statements, reminders and security alerts.
- newsletters: newsletters, marketing, promotions, digests and other bulk mail.
- codes: mail that gives a sign-in or verification code, a link to sign in or to verify an address or a device, or a password reset.
Also say whether it is a sign-in or verification code email, and give the reason in one short sentence of under 15 words, without quoting the email.
Answer only with the JSON object asked for. Nothing else you write is used: you cannot reply, forward, delete, move, open links or change anything; the app only reads the category, the reason and the yes or no.''';

  /// Moves [message] as [answer] says, if it is still where the rules
  /// left it. Returns whether it moved. [text] is the message's text
  /// ([whole]: all of it, else only the preview).
  bool _apply(
    StoredMessage message,
    AiSortAnswer answer,
    String text, {
    required bool whole,
    required String by,
  }) {
    final now = _store.messages.byId(message.id);
    final category = answer.decided;
    // Gone, moved by the user, or sorted meanwhile: left alone.
    if (now == null ||
        now.mailboxId != message.mailboxId ||
        now.category != MessageCategory.general ||
        category == MessageCategory.general) {
      _log(message, AiSortOutcome.kept, by: by, answer: answer);
      return false;
    }
    _store.transaction(() {
      _store.messages.updateCategories([
        CategoryDecision(
          messageId: message.id,
          category: category,
          source: CategorySource.rule,
          listId: now.listId,
          // Read at once when the text is here (none found in the whole
          // text: none to read); otherwise the next sync downloads and
          // reads it (CodeReader).
          code: category == MessageCategory.codes
              ? VerificationCodes.inMessage(message.subject, text) ??
                    (whole ? '' : null)
              : null,
        ),
      ]);
      _log(message, AiSortOutcome.applied, by: by, answer: answer);
    });
    return true;
  }

  void _log(
    StoredMessage message,
    AiSortOutcome outcome, {
    required String by,
    AiSortAnswer? answer,
  }) => AiSortLog(_store).add(
    AiSortEntry(
      messageId: message.id,
      outcome: outcome,
      at: _now(),
      category: answer?.decided,
      reason: answer?.reason,
      verification: answer?.isVerification ?? false,
      by: by,
      sender: message.from?.address.toLowerCase(),
      listId: message.listId,
    ),
  );

  /// Why [message] is where it is, when this feature put it there: who
  /// sorted it and the reason. Null otherwise (also while it is off).
  AiSortEntry? decisionFor(StoredMessage message) {
    if (!isOn) return null;
    final entry = AiSortLog(_store).forMessage(message.id);
    if (entry == null ||
        entry.outcome != AiSortOutcome.applied ||
        entry.category != message.category) {
      return null;
    }
    return entry;
  }

  /// "Not right?": the user says [message] belongs in [category]. That
  /// is where it stays (a re-sort keeps it), it is never asked about
  /// again, and, while "Learn from my corrections" is on, the sender's
  /// next mail the rules can't place goes there too, without asking the
  /// assistant (except Codes, which are known from each message).
  void correct(StoredMessage message, MessageCategory category) {
    _store.transaction(() {
      AiSortLog(_store).correct(message.id, category);
      _store.messages.updateCategories([
        CategoryDecision(
          messageId: message.id,
          category: category,
          source: CategorySource.rule,
          listId: message.listId,
        ),
      ]);
      // A code read for Codes no longer shows once it is elsewhere. Put
      // in Codes, its code is read from what is here (else the next sync
      // downloads and reads it: CodeReader).
      if (category != MessageCategory.codes) {
        _store.messages.setCode(message.id, '');
      } else if (VerificationCodes.inMessage(
            message.subject,
            _storedText(message),
          )
          case final code?) {
        _store.messages.setCode(message.id, code);
      }
      if (message.from?.address case final sender?
          when AppSettings(_store).learnFromCorrections) {
        SenderSortChoices(_store).choose(sender, category);
      }
    });
    onSorted?.call();
  }
}
