// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_protocol/mail_protocol.dart';
import 'package:mail_store/mail_store.dart';
import 'package:mail_sync/mail_sync.dart';
import 'package:mail_web/mail_web.dart';

/// The system keychain is missing or refused access. The app then stores
/// nothing secret rather than falling back to an unprotected file.
final class SecretStoreUnavailableException implements Exception {
  const SecretStoreUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'SecretStoreUnavailableException: $message';
}

/// Secrets (passwords, the database key) in the operating system's
/// keychain: libsecret on Linux, Credential Manager on Windows, the Android
/// Keystore on Android.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class KeychainSecretStore implements SecretStore {
  KeychainSecretStore()
    : _storage = const FlutterSecureStorage(
        // The plugin's default would silently wipe every secret after a
        // decryption error. Fail visibly instead.
        aOptions: AndroidOptions(resetOnError: false),
      );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) async {
    await _guard(() => _storage.write(key: key, value: value));
    // Read back: a keychain that silently drops writes would lose data.
    if (await read(key) != value) {
      throw const SecretStoreUnavailableException(
        'the keychain did not keep the value',
      );
    }
  }

  @override
  Future<void> delete(String key) => _guard(() => _storage.delete(key: key));

  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (e) {
      throw SecretStoreUnavailableException(e.message ?? e.code);
    } on MissingPluginException {
      throw const SecretStoreUnavailableException('no keychain on this system');
    }
  }
}

/// Account passwords for the sync engine, read from the keychain.
/// The app data sync code, from the keychain (null when sync is off).
final class KeychainSyncCodes implements SyncCodeProvider {
  const KeychainSyncCodes(this._secrets);

  /// The keychain entry with the code.
  static const key = 'sync-code';

  final SecretStore _secrets;

  @override
  Future<String?> syncCode() => _secrets.read(key);
}

/// Account secrets from the keychain: the password, or for an OAuth
/// account a current access token, renewed with its refresh token when it
/// is about to expire (one renewal at a time per account).
final class KeychainCredentials implements CredentialProvider {
  KeychainCredentials(this._secrets, {TokenClient? tokens})
    : _tokens = tokens ?? TokenClient(WebClient());

  final SecretStore _secrets;
  final TokenClient _tokens;
  final _renewing = <int, Future<String>>{};

  @override
  Future<String> passwordFor(Account account) async {
    if (account.usesOAuth) {
      return _renewing[account.id] ??= _accessToken(account).whenComplete(() {
        _renewing.remove(account.id);
      });
    }
    final password = await _secrets.read(account.keychainKey);
    if (password == null || password.isEmpty) {
      throw ImapAuthenticationException(
        'no saved password for ${account.email}',
      );
    }
    return password;
  }

  Future<String> _accessToken(Account account) async {
    final provider = switch (account.oauthProvider) {
      final id? => OAuthProvider.byId(id),
      null => null,
    };
    final stored = OAuthTokens.fromJson(
      await _secrets.read(account.keychainKey),
    );
    if (provider == null || stored == null) {
      throw ImapAuthenticationException('sign in to ${account.email} again');
    }
    // Renewed with the registration that issued the tokens.
    final issuer = provider.forTokens(stored);
    if (!stored.needsRefresh()) return stored.accessToken;
    final refresh = stored.refreshToken;
    if (refresh == null) {
      throw ImapAuthenticationException('sign in to ${account.email} again');
    }
    try {
      final renewed = (await _tokens.refresh(
        issuer,
        refresh,
      )).issuedTo(stored.registration);
      await _secrets.write(account.keychainKey, renewed.toJson());
      return renewed.accessToken;
    } on OAuthException catch (e) {
      throw switch (e.problem) {
        OAuthProblem.network => MailConnectionException(
          'can\'t reach ${issuer.name} sign-in',
        ),
        _ => ImapAuthenticationException(
          '${provider.name} asks to sign in to ${account.email} again',
        ),
      };
    }
  }
}

/// The user's own app registrations with OAuth providers ("bring your
/// own client ID"), used for new sign-ins when this build has none. One
/// per provider, in the keychain.
final class OwnOAuthClients {
  const OwnOAuthClients(this._secrets);

  final SecretStore _secrets;

  static String keyFor(String providerId) => 'oauth-client-$providerId';

  Future<OAuthRegistration?> read(String providerId) async =>
      OAuthRegistration.fromJson(await _secrets.read(keyFor(providerId)));

  Future<void> save(String providerId, OAuthRegistration registration) =>
      _secrets.write(keyFor(providerId), registration.toJson());

  Future<void> forget(String providerId) => _secrets.delete(keyFor(providerId));
}
