// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Base class for storage errors. Messages never contain mail content.
sealed class StoreException implements Exception {
  const StoreException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The key does not open this database (or the file is not one of ours).
/// The cache can be deleted and rebuilt from the server.
final class WrongKeyException extends StoreException {
  const WrongKeyException()
    : super('the database key does not match this database');
}

/// The loaded SQLite library cannot encrypt. Opening is refused rather
/// than storing mail unencrypted.
final class EncryptionUnavailableException extends StoreException {
  const EncryptionUnavailableException(super.message);
}

/// The database was created by a newer version of the app.
final class DatabaseTooNewException extends StoreException {
  const DatabaseTooNewException(int found, int supported)
    : super(
        'database schema $found is newer than this app supports ($supported)',
      );
}

/// A schema migration failed; the database was left unchanged.
final class MigrationException extends StoreException {
  const MigrationException(int version, Object cause)
    : super('migration to schema $version failed: $cause');
}

/// An account with this email address already exists.
final class DuplicateAccountException extends StoreException {
  const DuplicateAccountException(String email)
    : super('an account for $email already exists');
}
