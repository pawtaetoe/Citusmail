#!/bin/bash
# Builds the signed Android App Bundle for Google Play.
#
#   packaging/android/build-aab.sh     # writes build/packages/citusmail-<version>.aab
#
# Signs with the upload key in keys/citusmail-release.jks (alias "upload").
# Its password is read from the system keychain, never from a file:
#   secret-tool lookup service citusmail-release account upload-key
# Override the keystore with CITUSMAIL_KEYSTORE.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
keystore="${CITUSMAIL_KEYSTORE:-$root/keys/citusmail-release.jks}"
[[ -f "$keystore" ]] || { echo "error: no keystore at $keystore" >&2; exit 1; }

password="${CITUSMAIL_KEYSTORE_PASSWORD:-$(secret-tool lookup service citusmail-release account upload-key 2>/dev/null || true)}"
[[ -n "$password" ]] || { echo "error: upload key password not in the keychain" >&2; exit 1; }

version="$(sed -n 's/^version: *\([0-9.]*\)+\{0,1\}.*/\1/p' "$root/app/pubspec.yaml")"
# The Microsoft and Google registrations (see packaging/README.md), if given.
defines=()
for name in CITUSMAIL_MS_CLIENT_ID CITUSMAIL_GOOGLE_CLIENT_ID CITUSMAIL_GOOGLE_CLIENT_SECRET \
            CITUSMAIL_SAFE_BROWSING_KEY; do
  if [[ -n "${!name:-}" ]]; then
    defines+=("--dart-define=$name=${!name}")
  fi
done

cd "$root/app"
CITUSMAIL_KEYSTORE_PATH="$keystore" \
CITUSMAIL_KEY_ALIAS=upload \
CITUSMAIL_KEYSTORE_PASSWORD="$password" \
CITUSMAIL_KEY_PASSWORD="$password" \
  flutter build appbundle --release "${defines[@]}"
unset password

mkdir -p "$root/build/packages"
out="$root/build/packages/citusmail-$version.aab"
cp build/app/outputs/bundle/release/app-release.aab "$out"
echo "wrote $out"
