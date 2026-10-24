#!/bin/bash
# Builds the signed Android App Bundle for Google Play.
#
#   packaging/android/build-aab.sh     # writes build/packages/citusmail-<version>.aab
#
# Signs with the upload key in ~/citusmail-release.jks (alias "upload").
# Its password is read from the system keychain, never from a file:
#   secret-tool lookup service citusmail-release account upload-key
# Override the keystore with CITUSMAIL_KEYSTORE.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
keystore="${CITUSMAIL_KEYSTORE:-$HOME/citusmail-release.jks}"
[[ -f "$keystore" ]] || { echo "error: no keystore at $keystore" >&2; exit 1; }

password="$(secret-tool lookup service citusmail-release account upload-key)" || true
[[ -n "$password" ]] || { echo "error: upload key password not in the keychain" >&2; exit 1; }

version="$(sed -n 's/^version: *\([0-9.]*\)+\{0,1\}.*/\1/p' "$root/app/pubspec.yaml")"
# The Microsoft registration (public; see packaging/README.md), if given.
defines=()
if [[ -n "${CITUSMAIL_MS_CLIENT_ID:-}" ]]; then
  defines+=("--dart-define=CITUSMAIL_MS_CLIENT_ID=$CITUSMAIL_MS_CLIENT_ID")
fi

cd "$root/app"
FMAIL_KEYSTORE_PATH="$keystore" \
FMAIL_KEY_ALIAS=upload \
FMAIL_KEYSTORE_PASSWORD="$password" \
FMAIL_KEY_PASSWORD="$password" \
  flutter build appbundle --release "${defines[@]}"
unset password

mkdir -p "$root/build/packages"
out="$root/build/packages/citusmail-$version.aab"
cp build/app/outputs/bundle/release/app-release.aab "$out"
echo "wrote $out"
