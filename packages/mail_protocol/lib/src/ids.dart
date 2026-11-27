// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Typed ids for the rows mail_store keeps, so that an account id cannot
/// be passed where a message id is expected. Each is the row's `INTEGER
/// PRIMARY KEY`, and at run time it is that `int`: nothing changes in the
/// database or in anything stored.
///
/// They live here, the lowest package that everything dealing in them
/// shares (mail_ai ranks messages by id without the store), and
/// mail_store exports them too.
///
/// Convert with `MessageId(n)` and `.value` only at the edges: SQL row
/// mapping and query parameters, JSON and other serialisation, platform
/// channels. They implement [Object] (not `int`), so they are non-nullable
/// and work in generics, but cannot be mixed with each other or with `int`.
library;

/// The id of a stored message (`messages.id`). Not the Message-ID header.
extension type const MessageId(int value) implements Object {}

/// The id of a stored account (`accounts.id`).
extension type const AccountId(int value) implements Object {}

/// The id of a stored folder (`mailboxes.id`).
extension type const MailboxId(int value) implements Object {}
