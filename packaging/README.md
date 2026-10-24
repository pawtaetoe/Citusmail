# Packaging

CI builds every package on each push and attaches them to a **draft**
GitHub release when a version tag (`v0.1.0`) is pushed. The version comes
from `app/pubspec.yaml`.

| Platform | Package | Built by |
| --- | --- | --- |
| Android | `citusmail-<version>.apk` | `flutter build apk --release` |
| Linux | `citusmail_<version>-<build>_amd64.deb` | `packaging/linux/build-deb.sh` |
| Linux | `citusmail-<version>.flatpak` | `packaging/flatpak/build-flatpak.sh` |
| Windows | `citusmail-setup-<version>.exe` | `packaging/windows/citusmail.iss` (Inno Setup) |

The release also has `SHA256SUMS`.

## Android release signing

Android only updates an app with one signed by the same key, so the
release key must be kept safe and backed up. It never goes into the
repository (`*.jks` and `key.properties` are git-ignored).

The upload key is `~/citusmail-release.jks` (alias `upload`, RSA 4096).
Its password lives only in the system keychain:

```bash
secret-tool lookup service citusmail-release account upload-key
```

Google Play holds the app signing key (Play App Signing); this is the
upload key. Back up the `.jks` file and its password somewhere safe and
offline. If it is lost, Google support can reset the upload key, but
that takes days.

**Google Play bundle**: `packaging/android/build-aab.sh` writes
`build/packages/citusmail-<version>.aab`, signed with the upload key.
Raise the build number (`version: x.y.z+N` in `app/pubspec.yaml`) before
each upload: Play refuses a version code it has seen.

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
`$CITUSMAIL_MS_CLIENT_ID` on. Without it, Outlook addresses are told that
this build can't sign in to them.

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

**Other local release builds**: either the same environment variables as
CI below, or a git-ignored `app/android/key.properties`:

```properties
storeFile=/home/you/citusmail-release.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

**CI**: add these repository secrets (Settings → Secrets and variables →
Actions):

| Secret | Value |
| --- | --- |
| `FMAIL_KEYSTORE_BASE64` | output of `base64 -w0 ~/citusmail-release.jks` |
| `FMAIL_KEYSTORE_PASSWORD` | the store password |
| `FMAIL_KEY_ALIAS` | `upload` |
| `FMAIL_KEY_PASSWORD` | the key password |

A tagged release fails rather than publishing a debug-signed APK. Builds
without a key (local, pull requests) are signed with the debug key: fine
for testing, never for distribution.

## Android background mail

- **Periodic check** (default): WorkManager runs the app's Dart sync code
  in a background engine about every 15 minutes when online.
- **Instant mail** (Settings, off by default): a foreground service keeps
  an IMAP IDLE connection; Android requires its permanent "Citusmail is
  connected" notification. Type `specialUse` (no other type fits a mail
  push connection; `dataSync` is limited to 6 hours a day on Android 15).
  It restarts after a reboot when on.

Debug builds accept two test switches (release builds ignore them):

```bash
adb shell am start -n com.fluminaris.citusmail/.MainActivity --ez fmail.checkNow true
adb shell am start -n com.fluminaris.citusmail/.MainActivity --ez fmail.instant true
```

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
