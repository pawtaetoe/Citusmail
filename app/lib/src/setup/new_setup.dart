// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:mail_oauth/mail_oauth.dart';
import 'package:mail_setup/mail_setup.dart';
import 'package:mail_web/mail_web.dart';

import '../services/app_services.dart';
import '../services/secret_store.dart';
import 'oauth_browser.dart';
import 'setup_controller.dart';

/// A fresh add-account flow, wired to the real discovery, verification,
/// browser sign-in and keychain.
SetupController newSetupController(AppServices services) {
  final discovery = AccountDiscovery();
  const verifier = AccountVerifier();
  final browser = OAuthBrowser(TokenClient(WebClient()));
  return SetupController(
    discover: discovery.discover,
    verify: verifier.verify,
    save: services.addAccount,
    oauthSignIn: browser.signIn,
    verifyOAuth: (settings, token) =>
        verifier.verify(settings, token, oauth: true),
    saveOAuth: services.addOAuthAccount,
    ownClient: OwnOAuthClients(services.secrets).read,
    saveOwnClient: OwnOAuthClients(services.secrets).save,
  );
}
