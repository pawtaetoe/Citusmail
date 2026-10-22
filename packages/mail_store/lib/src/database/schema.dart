// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// One schema step. Versions are consecutive from 1; a migration runs in a
/// transaction, so it applies completely or not at all.
final class Migration {
  const Migration(this.version, this.statements);

  final int version;
  final List<String> statements;
}

/// The schema, as a list of migrations. Never edit a released migration:
/// add a new one. The cache can always be rebuilt from the server, but
/// migrations keep the user's local-only data (the outbox).
const List<Migration> schemaMigrations = [
  Migration(1, [
    // Accounts. Passwords are NOT stored here: they live in the system
    // keychain, keyed by account id.
    '''
    CREATE TABLE accounts (
      id INTEGER PRIMARY KEY,
      email TEXT NOT NULL UNIQUE COLLATE NOCASE,
      display_name TEXT,
      username TEXT NOT NULL,
      imap_host TEXT NOT NULL,
      imap_port INTEGER NOT NULL CHECK (imap_port BETWEEN 1 AND 65535),
      imap_security TEXT NOT NULL CHECK (imap_security IN ('implicitTls', 'startTls')),
      smtp_host TEXT NOT NULL,
      smtp_port INTEGER NOT NULL CHECK (smtp_port BETWEEN 1 AND 65535),
      smtp_security TEXT NOT NULL CHECK (smtp_security IN ('implicitTls', 'startTls')),
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    ) STRICT''',

    // Folders as the server lists them, with the sync state of each.
    '''
    CREATE TABLE mailboxes (
      id INTEGER PRIMARY KEY,
      account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
      encoded_name TEXT NOT NULL,
      name TEXT NOT NULL,
      delimiter TEXT,
      special_use TEXT,
      selectable INTEGER NOT NULL DEFAULT 1 CHECK (selectable IN (0, 1)),
      uid_validity INTEGER,
      uid_next INTEGER,
      highest_mod_seq INTEGER,
      last_sync_at INTEGER,
      UNIQUE (account_id, encoded_name)
    ) STRICT''',

    // Message summaries (from ENVELOPE and selected headers).
    '''
    CREATE TABLE messages (
      id INTEGER PRIMARY KEY,
      mailbox_id INTEGER NOT NULL REFERENCES mailboxes (id) ON DELETE CASCADE,
      uid INTEGER NOT NULL CHECK (uid > 0),
      message_id_header TEXT,
      in_reply_to TEXT,
      thread_references TEXT,
      subject TEXT,
      from_name TEXT,
      from_address TEXT,
      sent_at INTEGER,
      received_at INTEGER NOT NULL,
      size INTEGER NOT NULL DEFAULT 0,
      flags INTEGER NOT NULL DEFAULT 0,
      keywords TEXT NOT NULL DEFAULT '',
      mod_seq INTEGER,
      has_attachments INTEGER NOT NULL DEFAULT 0 CHECK (has_attachments IN (0, 1)),
      category TEXT NOT NULL DEFAULT 'people' CHECK (category IN ('people', 'newsletters', 'notifications')),
      category_source TEXT NOT NULL DEFAULT 'rule' CHECK (category_source IN ('rule', 'provider', 'manual')),
      snippet TEXT,
      UNIQUE (mailbox_id, uid)
    ) STRICT''',
    'CREATE INDEX messages_by_mailbox_date ON messages (mailbox_id, received_at DESC, id DESC)',
    'CREATE INDEX messages_by_category_date ON messages (category, received_at DESC, id DESC)',
    'CREATE INDEX messages_by_message_id ON messages (message_id_header)',

    '''
    CREATE TABLE message_addresses (
      message_id INTEGER NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('from', 'sender', 'reply_to', 'to', 'cc', 'bcc')),
      position INTEGER NOT NULL,
      name TEXT,
      address TEXT NOT NULL,
      PRIMARY KEY (message_id, kind, position)
    ) STRICT''',
    'CREATE INDEX message_addresses_by_address ON message_addresses (address COLLATE NOCASE)',

    // Selected headers needed by sorting, unsubscribe and phishing checks.
    '''
    CREATE TABLE message_headers (
      message_id INTEGER NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
      name TEXT NOT NULL CHECK (name = lower(name)),
      position INTEGER NOT NULL,
      value TEXT NOT NULL,
      PRIMARY KEY (message_id, name, position)
    ) STRICT''',

    // Full raw messages that have been downloaded (opened or prefetched).
    '''
    CREATE TABLE message_bodies (
      message_id INTEGER PRIMARY KEY REFERENCES messages (id) ON DELETE CASCADE,
      raw BLOB NOT NULL,
      fetched_at INTEGER NOT NULL
    ) STRICT''',

    // Full-text search; rowid = messages.id. Trigram matching works for
    // every script, including Chinese and Japanese without word spaces.
    "CREATE VIRTUAL TABLE message_search USING fts5 (subject, participants, body, tokenize = 'trigram remove_diacritics 1')",
    '''
    CREATE TRIGGER messages_search_cleanup AFTER DELETE ON messages BEGIN
      DELETE FROM message_search WHERE rowid = old.id;
    END''',

    // Actions done offline (or not yet confirmed by the server), replayed
    // in order on reconnect. Every action is safe to repeat.
    '''
    CREATE TABLE outbox (
      id INTEGER PRIMARY KEY,
      account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
      action TEXT NOT NULL,
      data BLOB,
      state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'failed')),
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at INTEGER NOT NULL,
      not_before INTEGER NOT NULL DEFAULT 0
    ) STRICT''',
    'CREATE INDEX outbox_by_account ON outbox (account_id, state, id)',
  ]),

  // Sorting (Stage 7). A message's shown category is now derived: the
  // user's choice for its mailing list or sender if there is one, else the
  // automatic decision. Keeping both lets a choice be undone without
  // downloading anything again.
  Migration(2, [
    // The automatic decision (rules now, provider labels later).
    '''
    ALTER TABLE messages ADD COLUMN auto_category TEXT NOT NULL DEFAULT 'people'
      CHECK (auto_category IN ('people', 'newsletters', 'notifications'))''',
    '''
    ALTER TABLE messages ADD COLUMN auto_source TEXT NOT NULL DEFAULT 'rule'
      CHECK (auto_source IN ('rule', 'provider'))''',
    // Normalized List-Id (lower case), so a choice can follow a list.
    'ALTER TABLE messages ADD COLUMN list_id TEXT',
    // Version 1 only had automatic decisions in practice (no UI could set
    // a manual one), so every stored category is carried over as one.
    '''
    UPDATE messages SET auto_category = category,
      auto_source = CASE WHEN category_source = 'provider' THEN 'provider' ELSE 'rule' END''',
    'UPDATE messages SET category_source = auto_source',
    'CREATE INDEX messages_by_from_address ON messages (from_address COLLATE NOCASE)',
    'CREATE INDEX messages_by_list_id ON messages (list_id) WHERE list_id IS NOT NULL',

    // "Move to People / Newsletters / Notifications": remembered per
    // mailing list or per sender. Local-only until multi-device app data
    // sync (M3). Keys are stored in lower case.
    '''
    CREATE TABLE category_choices (
      scope TEXT NOT NULL CHECK (scope IN ('sender', 'list')),
      key TEXT NOT NULL COLLATE NOCASE CHECK (length(key) BETWEEN 1 AND 512),
      category TEXT NOT NULL CHECK (category IN ('people', 'newsletters', 'notifications')),
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (scope, key)
    ) STRICT''',

    // Small app-wide values (e.g. which sorting rules version the stored
    // categories were computed with).
    '''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) STRICT''',
  ]),

  // Sorting is fully automatic (decided after Stage 7): "Move to" choices
  // are gone, so the shown category is the automatic one again. Custom
  // folders replace manual sorting.
  Migration(3, [
    'UPDATE messages SET category = auto_category, category_source = auto_source',
    'DROP TABLE category_choices',
    'DROP INDEX messages_by_list_id',
    'ALTER TABLE messages DROP COLUMN auto_category',
    'ALTER TABLE messages DROP COLUMN auto_source',
  ]),

  // Writing mail (Stage 9): drafts being written, saved here every few
  // seconds so nothing is lost if the app stops. Closing the window moves
  // a draft to the server's Drafts folder.
  Migration(4, [
    '''
    CREATE TABLE drafts (
      id INTEGER PRIMARY KEY,
      account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
      content TEXT NOT NULL,
      saved_message_id TEXT,
      updated_at INTEGER NOT NULL
    ) STRICT''',
    '''
    CREATE TABLE draft_attachments (
      draft_id INTEGER NOT NULL REFERENCES drafts (id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      file_name TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      data BLOB NOT NULL,
      PRIMARY KEY (draft_id, position)
    ) STRICT''',
  ]),

  // Custom folders (Stage 10): the user's rules that move new inbox mail
  // into a folder on the server. A rule goes when its folder goes (deleted
  // or renamed elsewhere), so mail never lands somewhere unexpected.
  Migration(5, [
    '''
    CREATE TABLE folder_rules (
      id INTEGER PRIMARY KEY,
      account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
      mailbox_id INTEGER NOT NULL REFERENCES mailboxes (id) ON DELETE CASCADE,
      field TEXT NOT NULL CHECK (field IN ('fromAddress', 'fromDomain', 'toAddress', 'subject')),
      value TEXT NOT NULL CHECK (length(value) BETWEEN 1 AND 320),
      applies_from INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    ) STRICT''',
    'CREATE INDEX folder_rules_by_account ON folder_rules (account_id, id)',
    // Messages a rule already moved (by Message-ID): never moved twice, so
    // one the user brings back to the inbox stays there.
    '''
    CREATE TABLE rule_moves (
      account_id INTEGER NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
      message_id_header TEXT NOT NULL,
      moved_at INTEGER NOT NULL,
      PRIMARY KEY (account_id, message_id_header)
    ) STRICT''',
  ]),
];
