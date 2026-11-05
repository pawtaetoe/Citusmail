# Packaging

CI builds every package on each push. **A release is made by raising the
version**: when `main` has an `app/pubspec.yaml` version with no tag yet
(after a pull request such as "Release 0.4.2" is merged), that run builds
the release-signed packages, creates the tag (`v0.4.2`) on that commit and
publishes the GitHub release with them. Nothing to tag by hand.

| Platform | Package | Built by |
| --- | --- | --- |
| Android (GitHub) | `citusmail-<version>.apk` | `flutter build apk --release --flavor github` |
| Android (Google Play) | `citusmail-<version>.aab` | `flutter build appbundle --release --flavor play` |
| Linux | `citusmail_<version>-<build>_amd64.deb` | `packaging/linux/build-deb.sh` |
| Linux | `citusmail-<version>.flatpak` | `packaging/flatpak/build-flatpak.sh` |
| Windows | `citusmail-setup-<version>.exe` | `packaging/windows/citusmail.iss` (Inno Setup) |

The release also has `SHA256SUMS`. Both Android files are signed with the
same key and built with the same `--dart-define`s; the `.aab` is the one
to upload to Google Play (see [Google Play](#google-play) below).

To release:

1. Raise `version:` in `app/pubspec.yaml` (`0.4.1+8` to `0.4.2+9`: the
   number after `+` must always go up, Android needs it) and add the
   release to `packaging/linux/com.fluminaris.citusmail.metainfo.xml`.
2. Merge that to `main`. The CI run on `main` releases it.

Pushing a version tag by hand still works. The tag must be on a commit
whose version matches it (`v0.4.2` needs `version: 0.4.2+N`); CI stops
otherwise, before building anything.

## Android release signing

Android only updates an app with one signed by the same key, so the
release key must be kept safe and backed up. It never goes into the
repository (`*.jks` and `key.properties` are git-ignored).

The upload key is `keys/citusmail-release.jks` (alias `upload`, RSA 4096).
Its password lives only in the system keychain:

```bash
secret-tool lookup service citusmail-release account upload-key
```

Google Play holds the app signing key (Play App Signing); this is the
upload key. Back up the `.jks` file and its password somewhere safe and
offline. If it is lost, Google support can reset the upload key, but
that takes days.

**Google Play bundle**: every release has `citusmail-<version>.aab`,
built by CI with the same key. To build one locally,
`packaging/android/build-aab.sh` writes
`build/packages/citusmail-<version>.aab` (the `play` flavor), signed with
the upload key. Raise the build number (`version: x.y.z+N` in
`app/pubspec.yaml`) before each upload: Play refuses a version code it
has seen.

**Outlook sign-in** needs the app's registration with Microsoft (free):
in the [Microsoft Entra admin center](https://entra.microsoft.com), App
registrations > New registration:

- Supported accounts: *personal Microsoft accounts and accounts in any
  organizational directory*.
- Platform *Mobile and desktop applications*, redirect URIs
  `http://127.0.0.1` (desktops; any port is allowed) and
  `com.fluminaris.citusmail://oauth` (Android).
- Authentication: *Allow public client flows* = Yes. No client secret.
- API permissions (delegated): `IMAP.AccessAsUser.All`, `SMTP.Send` and
  `offline_access`.

Its *Application (client) ID* is public. Builds take it as
`--dart-define=CITUSMAIL_MS_CLIENT_ID=<id>`; `build-aab.sh` passes
`$CITUSMAIL_MS_CLIENT_ID` on, and CI takes it from the repository variable
of that name (below). Without it, Outlook users can enter their own client
ID during setup: the same registration in their own Entra directory (the
app shows the steps).

**Google sign-in** (Gmail) needs a Google Cloud project (free): in the
[Google Cloud console](https://console.cloud.google.com/apis/credentials):

- Turn on the Gmail API.
- OAuth consent screen: *External*, with the scope
  `https://mail.google.com/`. While the app is in *Testing*, only listed
  test users can sign in, and Google ends their sign-in after 7 days.
  Publishing for everyone needs Google's verification, including a
  security assessment for this (restricted) scope.
- Credentials > Create OAuth client ID > *Desktop app*. The redirect is
  `http://127.0.0.1` on any port; Android uses the same loopback
  receiver, because Google no longer allows custom app links for new
  clients.

Builds take `--dart-define=CITUSMAIL_GOOGLE_CLIENT_ID=<id>` and
`--dart-define=CITUSMAIL_GOOGLE_CLIENT_SECRET=<secret>`; `build-aab.sh`
passes both on. Google calls the secret of a desktop client "not treated
as a secret": every copy of the app carries it. Without them, the app
offers Gmail users to enter their own client ID instead (the same steps,
in their own project).

**Google Safe Browsing** (optional link checks, off until the user turns
them on) needs a Google API key with the Safe Browsing API enabled, passed
as `--dart-define=CITUSMAIL_SAFE_BROWSING_KEY=<key>` (`build-aab.sh`
passes it on). Without it, users who turn the checks on enter their own
key. Restrict the key to the Safe Browsing API in the Cloud console.

**Other local release builds**: either the same environment variables as
CI below, or a git-ignored `app/android/key.properties`:

```properties
storeFile=/path/to/Fmail/keys/citusmail-release.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

**CI**: add these secrets, either as repository secrets (Settings → Secrets
and variables → Actions) or in an environment named `release` (Settings →
Environments), where only the signed Android build of a version tag
(`build-android-release`) can read them:

| Secret | Value |
| --- | --- |
| `CITUSMAIL_KEYSTORE_BASE64` | output of `base64 -w0 ~/citusmail-release.jks` |
| `CITUSMAIL_KEYSTORE_PASSWORD` | the store password |
| `CITUSMAIL_KEY_ALIAS` | `upload` |
| `CITUSMAIL_KEY_PASSWORD` | the key password |
| `CITUSMAIL_GOOGLE_CLIENT_SECRET` | Google desktop client secret (optional) |
| `CITUSMAIL_SAFE_BROWSING_KEY` | Safe Browsing API key (optional) |

Signing secrets saved under the app's former names (`FMAIL_KEYSTORE_BASE64`,
`FMAIL_KEYSTORE_PASSWORD`, `FMAIL_KEY_ALIAS`, `FMAIL_KEY_PASSWORD`) still work.

And these repository **variables** (same page, *Variables* tab): the client
IDs are public, so they need not be secrets. Every CI build (APK, Linux,
Windows) passes all four to `flutter build` as `--dart-define`; any left
empty means users bring their own.

| Variable | Value |
| --- | --- |
| `CITUSMAIL_MS_CLIENT_ID` | Microsoft Entra Application (client) ID |
| `CITUSMAIL_GOOGLE_CLIENT_ID` | Google desktop client ID |

A tagged release fails rather than publishing a debug-signed APK. Builds
without a key (local, pull requests) are signed with the debug key: fine
for testing, never for distribution.

## Android background mail

- **Periodic check** (default, both flavors): WorkManager runs the app's
  Dart sync code in a background engine about every 5 minutes when online
  (a chain of one-off checks, with a 15-minute periodic check as a safety
  net).
- **Instant mail** (Settings, on unless turned off; both flavors): a
  foreground service keeps
  an IMAP IDLE connection; Android requires its permanent "Citusmail is
  connected" notification (a silent, minimum-importance channel). Type
  `specialUse` (no other type fits a mail push connection; `dataSync` is
  limited to 6 hours a day on Android 15). It restarts after a reboot
  when on. Once per install the app asks Android's one-tap "run in the
  background" question (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`), since
  without a push server of ours nothing else can keep the connection
  while the phone sleeps.

Debug builds accept two test switches (release builds ignore them):

```bash
adb shell am start -n com.fluminaris.citusmail/.MainActivity --ez citusmail.checkNow true
adb shell am start -n com.fluminaris.citusmail/.MainActivity --ez citusmail.instant true
```

## Android flavors: GitHub and Google Play

The Android app has two product flavors (`app/android/app/build.gradle.kts`),
so every Android build needs `--flavor`:

| Flavor | Built as | Goes to | Instant mail |
| --- | --- | --- | --- |
| `github` (default in Android Studio) | `citusmail-<version>.apk` | GitHub releases | yes |
| `play` | `citusmail-<version>.aab` | Google Play | yes (declared in Play Console) |

The two builds are the same app today. Instant mail is a foreground
service of type `specialUse`, which Google Play reviews by hand: the Play
build needs the declaration below (Foreground service declaration). The
flavors stay so the Play build can differ again if Play ever asks.

`packaging/android/check-play-bundle.sh <file.aab>` reads the bundle's
manifest and fails if Instant mail (its service, the special-use
permission and type, the boot receiver) or WorkManager's check is
missing. CI runs it on every Android build, and checks that the GitHub
APK has Instant mail too.

Outputs of a flavored build: `app/build/app/outputs/flutter-apk/app-github-release.apk`
and `app/build/app/outputs/bundle/playRelease/app-play-release.aab`.

## Google Play

Upload `citusmail-<version>.aab` from the GitHub release (or from
`build-aab.sh`), never the APK. Play App Signing re-signs it with Google's
key, so the Play app and the GitHub APK cannot update each other:
switching between them means uninstalling first.

Play Console checklist (closed or open testing):

- **App signing**: Play App Signing on; the key in the CI secrets is the
  upload key (above).
- **Privacy policy**: `https://citusmail.fluminaris.com/privacy-policy`
  (also in the app: Settings > About > Privacy policy).
- **Data safety**: no data collected, no data shared. Data is encrypted
  in transit (TLS to the user's own mail servers) and stored encrypted on
  the device; users can delete it (remove an account, or uninstall). Mail
  goes only to the mail servers the user sets up. The optional outside
  checks (Google Safe Browsing, VirusTotal, under Settings > Advanced) are
  off until the user turns them on and send only what the privacy policy
  lists; read Play's data safety help on user-initiated transfers to
  confirm "not shared" still fits before submitting.
- **Content rating**: fill in the questionnaire. It is an email app, so
  users can exchange messages with other people (with addresses they
  choose); no ads, no purchases, no location.
- **Target audience**: 13 and over. Not designed for children.
- **Ads**: no ads.
- **App access** (sign-in for reviewers): give a test mail account the
  reviewers can add with an **app password** (for example a Gmail or
  Fastmail test account with an app password, or a mailbox on your own
  server), with the steps: Add account > enter the address > enter the
  app password. Don't give a password that opens anything else.
- **Foreground service declaration** (App content > Foreground service
  permissions): the bundle has `FOREGROUND_SERVICE_SPECIAL_USE` for
  Instant mail. Declare:
  - Type: **Special use**.
  - Description, for example: "Instant mail: when the user turns it on
    in Settings, the app keeps one connection to the user's own mail
    server (IMAP IDLE) so new mail and sign-in codes arrive immediately.
    Android shows a permanent notification while it runs, and the user
    can turn it off at any time. No other foreground service type fits:
    dataSync is limited to 6 hours a day, and the connection carries no
    data until mail arrives."
  - A short video: Settings > Instant mail on, the "Citusmail is
    connected" notification, an email arriving while the app is closed.
- **Battery optimization exemption**: the app asks Android's one-tap
  dialog (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`). Play allows it when the
  app's core function needs it and Firebase push can't be used; if Play
  asks, the reason is the same as Instant mail's: mail is delivered over
  the user's own connection to their mail server, with no server of
  ours to send push messages.
- **Store listing**:
  - App icon (512 × 512): `assets/icon/png/512.png`.
  - Feature graphic (1024 × 500): `packaging/android/play/feature-graphic.png`,
    rendered from `feature-graphic.svg` next to it (IBM Plex Sans from
    `app/assets/fonts`).
  - Phone screenshots: `docs/screenshots/readme_phone*.png` and
    `readme_subscriptions.png`.
  - Short description, for example "Fast, private email that stays yours".
- **Testers**: a closed test needs a list of testers (email addresses or
  a Google group); new personal developer accounts must run a closed
  test with enough testers for the required time before production.

## Linux

The `.deb` installs to `/opt/citusmail`, with `/usr/bin/citusmail`, a desktop
entry, icons and AppStream metadata. It needs GTK 3 and libsecret, and a
keychain (GNOME Keyring or KWallet).

The Flatpak is built from the release bundle on the
`org.freedesktop.Platform` 25.08 runtime (nothing is compiled inside). Its
sandbox allows only:

| Permission | Why |
| --- | --- |
| `--share=network` | your own mail servers |
| `--socket=wayland`, `--socket=fallback-x11`, `--device=dri`, `--share=ipc` | the window |
| `--talk-name=org.freedesktop.secrets` | passwords in the system keychain |
| `--talk-name=org.freedesktop.Notifications` | new-mail notifications |
| `--filesystem=xdg-download` | saving attachments to Downloads |

No access to your home folder; the file picker and links use portals.

```bash
flatpak install --user citusmail-0.1.0.flatpak
```

## Windows

Inno Setup installs for the current user (no administrator rights) into
`%LOCALAPPDATA%\Programs\Citusmail`. Its Start-menu shortcut carries the app
identity Windows needs to show notifications. The installer is **not
code-signed** (that needs a paid certificate), so SmartScreen shows
"unknown publisher". Uninstalling keeps local data and keychain entries.
