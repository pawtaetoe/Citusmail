// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mail_compose/mail_compose.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_view/mail_view.dart';

import '../services/app_services.dart';
import 'mail_location.dart';

/// One Smart Inbox section as shown: its newest messages and counts.
final class SectionPreview {
  const SectionPreview(this.section, this.count, this.messages);

  final SmartSection section;
  final SectionCount count;
  final List<StoredMessage> messages;
}

/// What the reading pane shows.
sealed class ReaderState {
  const ReaderState();
}

final class ReaderEmpty extends ReaderState {
  const ReaderEmpty();
}

final class ReaderLoading extends ReaderState {
  const ReaderLoading(this.message);

  final StoredMessage message;
}

final class ReaderReady extends ReaderState {
  const ReaderReady(
    this.message,
    this.view, {
    required this.to,
    required this.cc,
  });

  final StoredMessage message;
  final MessageView view;
  final List<MailAddress> to;
  final List<MailAddress> cc;
}

final class ReaderFailed extends ReaderState {
  const ReaderFailed(this.message, this.reason);

  final StoredMessage message;
  final String reason;
}

/// The state behind the mail screen: where the user is, what the list
/// shows, which message is open. Reads come straight from the store; slow
/// work (sync, downloads) goes to the background worker.
final class MailController extends ChangeNotifier {
  MailController(this.services) {
    _events = services.worker.events.listen(_onSyncEvent);
    _reload();
  }

  final AppServices services;
  late final StreamSubscription<SyncEvent> _events;
  Timer? _refreshSoon;
  bool _disposed = false;

  MailStore get _store => services.store;

  /// How many messages a Smart Inbox section shows before "Show all".
  static const previewSize = 5;
  static const pageSize = 50;

  // ------------------------------------------------------------- location

  MailLocation _location = const InboxLocation();
  MailLocation get location => _location;

  bool _smart = true;

  /// Smart (sections) or Classic (one list) inbox.
  bool get smartLayout => _smart;

  bool get showsSections => _location is InboxLocation && _smart;

  void goTo(MailLocation location) {
    _location = location;
    _messages = const [];
    _reachedEnd = false;
    _reload();
  }

  void setSmartLayout(bool smart) {
    if (_smart == smart) return;
    _smart = smart;
    goTo(_location is InboxLocation ? _location : const InboxLocation());
  }

  void search(String text) {
    final trimmed = text.trim();
    goTo(trimmed.isEmpty ? const InboxLocation() : SearchLocation(trimmed));
  }

  // ----------------------------------------------------------------- lists

  List<SectionPreview> _sections = const [];

  /// Smart Inbox sections that have mail, in order.
  List<SectionPreview> get sections => _sections;

  List<StoredMessage> _messages = const [];

  /// The list for every location except the Smart Inbox.
  List<StoredMessage> get messages => _messages;

  bool _reachedEnd = false;
  bool _loadingOlder = false;

  /// Whether more (stored or on the server) may follow.
  bool get canLoadMore =>
      !_reachedEnd &&
      _location is! SearchLocation &&
      _location is! OutboxLocation;
  bool get loadingOlder => _loadingOlder;

  Map<SmartSection, SectionCount> inboxCounts({int? accountId}) => _store
      .messages
      .sectionCounts(accountIds: accountId == null ? null : [accountId]);

  int unreadIn(int mailboxId) => _store.messages.unreadCount(mailboxId);

  void _reload() {
    final location = _location;
    if (location is InboxLocation && _smart) {
      final counts = inboxCounts(accountId: location.accountId);
      _sections = [
        for (final section in SmartSection.values)
          if (counts[section]!.total > 0)
            SectionPreview(
              section,
              counts[section]!,
              _store.messages.list(
                MessageQuery.smart(
                  section,
                  accountIds: _accounts(location.accountId),
                  limit: previewSize,
                ),
              ),
            ),
      ];
    } else {
      // Keep at least as many messages as already shown.
      final wanted = _messages.length < pageSize ? pageSize : _messages.length;
      _messages = switch (location) {
        SearchLocation(:final text) => _store.messages.search(text, limit: 200),
        OutboxLocation() => const [],
        _ => _store.messages.list(_query(location, limit: wanted)),
      };
    }
    _refreshSelected();
    _notify();
  }

  MessageQuery _query(
    MailLocation location, {
    StoredMessage? before,
    int limit = pageSize,
  }) => switch (location) {
    InboxLocation(:final accountId) => MessageQuery.inbox(
      accountIds: _accounts(accountId),
      before: before,
      limit: limit,
    ),
    SectionLocation(:final section, :final accountId) => MessageQuery.smart(
      section,
      accountIds: _accounts(accountId),
      before: before,
      limit: limit,
    ),
    FolderLocation(:final mailboxId) => MessageQuery(
      mailboxIds: [mailboxId],
      before: before,
      limit: limit,
    ),
    PinsLocation() => MessageQuery(
      flaggedOnly: true,
      before: before,
      limit: limit,
    ),
    SearchLocation() ||
    OutboxLocation() => throw StateError('not a paged message list'),
  };

  static List<int>? _accounts(int? accountId) =>
      accountId == null ? null : [accountId];

  /// Shows more of the list: stored messages first, then older mail from
  /// the server.
  Future<void> loadMore() async {
    if (!canLoadMore || _loadingOlder || _messages.isEmpty) return;
    final location = _location;
    final page = _store.messages.list(_query(location, before: _messages.last));
    if (page.isNotEmpty) {
      _messages = [..._messages, ...page];
      _notify();
      return;
    }
    final folders = _foldersToExtend(location);
    if (folders.isEmpty) {
      _reachedEnd = true;
      _notify();
      return;
    }
    _loadingOlder = true;
    _notify();
    var added = 0;
    try {
      for (final mailboxId in folders) {
        added += await services.worker.fetchOlder(mailboxId);
      }
    } on SyncWorkerException {
      // Offline: try again on the next scroll.
    } finally {
      _loadingOlder = false;
    }
    if (_disposed || _location != location) return;
    if (added == 0) _reachedEnd = true;
    final more = _store.messages.list(_query(location, before: _messages.last));
    _messages = [..._messages, ...more];
    _notify();
  }

  /// Server folders whose older mail would extend [location].
  List<int> _foldersToExtend(MailLocation location) => switch (location) {
    FolderLocation(:final mailboxId) => [mailboxId],
    InboxLocation(:final accountId) || SectionLocation(:final accountId) => [
      for (final account in _store.accounts.all())
        if (accountId == null || account.id == accountId)
          ?_store.mailboxes.inbox(account.id)?.id,
    ],
    _ => const [],
  };

  // ---------------------------------------------------------------- reader

  ReaderState _reader = const ReaderEmpty();
  ReaderState get reader => _reader;

  StoredMessage? get selected => switch (_reader) {
    ReaderEmpty() => null,
    ReaderLoading(:final message) ||
    ReaderReady(:final message) ||
    ReaderFailed(:final message) => message,
  };

  /// Opens [message]: marks it read and shows it, downloading it first if
  /// needed.
  Future<void> open(StoredMessage message) async {
    if (_isDraft(message)) return _editDraft(message);
    if (!message.flags.seen) {
      services.actions.markRead([message]);
      services.worker.requestSync(message.accountId);
      message = _store.messages.byId(message.id) ?? message;
    }
    _reader = ReaderLoading(message);
    _reload();
    try {
      if (_store.messages.body(message.id) == null) {
        await services.worker.loadBody(message.id);
      }
      final raw = _store.messages.body(message.id);
      if (raw == null) throw const BodyUnavailableException(BodyProblem.gone);
      // Parsing a large message must not block the UI.
      final view = await compute(_parseMessage, raw);
      if (_disposed || selected?.id != message.id) return;
      _reader = ReaderReady(
        _store.messages.byId(message.id) ?? message,
        view,
        to: _store.messages.addresses(message.id, 'to'),
        cc: _store.messages.addresses(message.id, 'cc'),
      );
    } on BodyUnavailableException catch (e) {
      if (_disposed || selected?.id != message.id) return;
      _reader = ReaderFailed(message, switch (e.problem) {
        BodyProblem.tooLarge => 'This message is too large to show.',
        BodyProblem.gone => 'This message is no longer on the server.',
        BodyProblem.folderChanged =>
          'The folder changed on the server. Try again after the next sync.',
      });
    } on SyncWorkerException catch (e) {
      if (_disposed || selected?.id != message.id) return;
      _reader = ReaderFailed(message, switch (e.failure.kind) {
        SyncFailureKind.network =>
          'Can\'t reach the server. The message opens once you\'re online.',
        SyncFailureKind.authentication =>
          'The server didn\'t accept your password.',
        SyncFailureKind.security =>
          'The connection was refused for security reasons.',
        SyncFailureKind.server =>
          'The server had a problem: ${e.failure.message}',
      });
    }
    _notify();
  }

  // ----------------------------------------------------------- composing

  /// Opens the compose window (set by the screen that can show it).
  void Function(Draft draft)? onCompose;

  /// A problem to tell the user about (set by the screen).
  void Function(String message)? onNotice;

  /// A new message from the account being viewed (or the first account).
  void compose() {
    final accountId =
        _location.accountId ?? _store.accounts.all().firstOrNull?.id;
    if (accountId != null) onCompose?.call(Draft(accountId: accountId));
  }

  /// A new message to a `mailto:` link's address (and subject, if given).
  void composeTo(Uri mailto) {
    final accountId =
        selected?.accountId ?? _store.accounts.all().firstOrNull?.id;
    if (accountId == null) return;
    final parsed = const AddressParser().parse(
      Uri.decodeComponent(mailto.path),
    );
    onCompose?.call(
      Draft(
        accountId: accountId,
        to: parsed.mailboxes,
        subject: mailto.queryParameters['subject'] ?? '',
      ),
    );
  }

  void reply(ReaderReady reader) =>
      onCompose?.call(services.replies.reply(reader.message, reader.view));

  void replyAll(ReaderReady reader) =>
      onCompose?.call(services.replies.replyAll(reader.message, reader.view));

  void forward(ReaderReady reader) =>
      onCompose?.call(services.replies.forward(reader.message, reader.view));

  bool _isDraft(StoredMessage m) =>
      m.flags.draft &&
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.drafts;

  /// A draft from the Drafts folder opens in the compose window.
  Future<void> _editDraft(StoredMessage message) async {
    try {
      if (_store.messages.body(message.id) == null) {
        await services.worker.loadBody(message.id);
      }
      final raw = _store.messages.body(message.id);
      if (raw == null || _disposed) return;
      onCompose?.call(services.drafts.fromDraftsFolder(message, raw));
    } on SyncWorkerException {
      onNotice?.call('Can\'t open the draft while offline.');
    } on BodyUnavailableException {
      onNotice?.call('This draft is no longer on the server.');
    }
  }

  // ------------------------------------------------------ custom folders

  /// Creates a folder on the server and opens it. Returns an error to
  /// show, or null on success.
  Future<String?> createFolder(int accountId, String name) async {
    try {
      final id = await services.worker.createFolder(accountId, name);
      if (!_disposed) goTo(FolderLocation(id, accountId));
      return null;
    } on ArgumentError catch (e) {
      return switch (e.message) {
        final String message when message.contains('separator') =>
          'Folder names can\'t contain "${message.split('"')[1]}" on this server.',
        final String message when message.contains('INBOX') =>
          'Inbox already exists.',
        _ => 'That can\'t be a folder name.',
      };
    } on SyncWorkerException catch (e) {
      return e.failure.kind == SyncFailureKind.network
          ? 'Folders can only be created while online.'
          : 'The server refused: ${e.failure.message}';
    }
  }

  /// Whether rules can move mail into [mailbox] (not the inbox, Drafts or
  /// Sent).
  bool canHaveRules(StoredMailbox mailbox) =>
      !mailbox.isInbox &&
      mailbox.selectable &&
      mailbox.specialUse != SpecialUse.drafts &&
      mailbox.specialUse != SpecialUse.sent;

  List<FolderRule> rulesFor(int mailboxId) =>
      _store.folderRules.forMailbox(mailboxId);

  /// Adds a rule; with [includeExisting] the inbox is filed at once (with
  /// the next sync). Returns an error to show, or null.
  String? addRule(
    StoredMailbox mailbox,
    RuleField field,
    String value, {
    bool includeExisting = false,
  }) {
    try {
      _store.folderRules.add(
        accountId: mailbox.accountId,
        mailboxId: mailbox.id,
        field: field,
        value: value,
        includeExisting: includeExisting,
      );
    } on ArgumentError {
      return switch (field) {
        RuleField.fromAddress ||
        RuleField.toAddress => 'Enter an email address.',
        RuleField.fromDomain => 'Enter a domain, like example.com.',
        RuleField.subject => 'Enter some text.',
      };
    }
    if (includeExisting) services.worker.requestSync(mailbox.accountId);
    _notify();
    return null;
  }

  void removeRule(FolderRule rule) {
    _store.folderRules.remove(rule.id);
    _notify();
  }

  /// "Always move mail from this sender here", then moves this message.
  void moveAlways(StoredMessage message, StoredMailbox target) {
    final from = message.from?.address;
    if (from != null && canHaveRules(target)) {
      try {
        _store.folderRules.add(
          accountId: target.accountId,
          mailboxId: target.id,
          field: RuleField.fromAddress,
          value: from,
        );
      } on ArgumentError {
        // An address a rule can't hold: just move this one.
      }
    }
    moveTo(message, target);
  }

  // ---------------------------------------------------------------- outbox

  /// Messages waiting to be sent or failed, oldest first.
  List<OutboxEntry> get outbox => _store.outbox.sends();

  void retrySend(OutboxEntry entry) {
    _store.outbox.retryFailed(entry.id);
    services.worker.requestSync(entry.accountId);
    _reload();
  }

  void discardSend(OutboxEntry entry) {
    _store.outbox.discardFailed(entry.id);
    _reload();
  }

  void closeMessage() {
    _reader = const ReaderEmpty();
    _notify();
  }

  /// After a refresh: keep the open message current, or close it if it
  /// left the store (moved or deleted).
  void _refreshSelected() {
    final current = selected;
    if (current == null) return;
    final fresh = _store.messages.byId(current.id);
    if (fresh == null) {
      _reader = const ReaderEmpty();
      return;
    }
    _reader = switch (_reader) {
      ReaderLoading() => ReaderLoading(fresh),
      ReaderReady(:final view, :final to, :final cc) => ReaderReady(
        fresh,
        view,
        to: to,
        cc: cc,
      ),
      ReaderFailed(:final reason) => ReaderFailed(fresh, reason),
      ReaderEmpty() => const ReaderEmpty(),
    };
  }

  // --------------------------------------------------------------- actions

  void togglePin(StoredMessage m) => _act(
    m,
    () => services.actions.markFlagged([m], flagged: !m.flags.flagged),
  );

  void toggleRead(StoredMessage m) =>
      _act(m, () => services.actions.markRead([m], read: !m.flags.seen));

  /// The account's Archive folder, if it has one.
  StoredMailbox? archiveFor(StoredMessage m) =>
      _store.mailboxes.bySpecialUse(m.accountId, SpecialUse.archive);

  bool isInTrash(StoredMessage m) =>
      _store.mailboxes.byId(m.mailboxId)?.specialUse == SpecialUse.trash;

  void archive(StoredMessage m) {
    final archive = archiveFor(m);
    if (archive != null) moveTo(m, archive);
  }

  void moveTo(StoredMessage m, StoredMailbox target) =>
      _act(m, () => services.actions.move([m], target), leaves: true);

  void delete(StoredMessage m) =>
      _act(m, () => services.actions.delete([m]), leaves: true);

  /// Marks every unread message of a Smart Inbox section as read.
  void markSectionRead(SmartSection section) {
    final location = _location;
    final unread = _store.messages
        .list(
          MessageQuery.smart(
            section,
            accountIds: _accounts(location.accountId),
            limit: 500,
          ),
        )
        .where((m) => !m.flags.seen)
        .toList();
    if (unread.isEmpty) return;
    services.actions.markRead(unread);
    for (final accountId in unread.map((m) => m.accountId).toSet()) {
      services.worker.requestSync(accountId);
    }
    _reload();
  }

  /// Folders of [accountId] a message can be moved to.
  List<StoredMailbox> moveTargets(StoredMessage m) => [
    for (final box in _store.mailboxes.forAccount(m.accountId))
      if (box.selectable && box.id != m.mailboxId) box,
  ];

  void _act(StoredMessage m, void Function() change, {bool leaves = false}) {
    change();
    services.worker.requestSync(m.accountId);
    if (leaves && selected?.id == m.id) _reader = const ReaderEmpty();
    _reload();
  }

  // ------------------------------------------------------------------ sync

  final Map<int, SyncEvent> _lastEvent = {};

  /// The latest sync news of an account (syncing, synced, failed).
  SyncEvent? lastEvent(int accountId) => _lastEvent[accountId];

  Future<void> syncNow() async {
    try {
      await services.worker.syncNow();
    } on SyncWorkerException {
      // Shown through the account's failure event.
    }
  }

  void _onSyncEvent(SyncEvent event) {
    _lastEvent[event.accountId] = event;
    // Several events arrive close together; refresh once.
    _refreshSoon?.cancel();
    _refreshSoon = Timer(const Duration(milliseconds: 150), () {
      if (!_disposed) _reload();
    });
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshSoon?.cancel();
    unawaited(_events.cancel());
    super.dispose();
  }
}

/// Top level, so [compute] sends only the bytes to the helper isolate.
MessageView _parseMessage(Uint8List raw) => MessageView.parse(raw);
