#!/usr/bin/env bash
# Builds a Flatpak bundle from the Linux release bundle.
#
#   (cd app && flutter build linux --release)
#   packaging/flatpak/build-flatpak.sh       # writes build/packages/citusmail-<version>.flatpak
#
# Needs only the org.freedesktop.Platform runtime (the app is already
# compiled; nothing is built inside the sandbox).
#
# Sandbox permissions, and why:
#   --share=network                    the user's own mail servers
#   --socket=wayland / fallback-x11, --device=dri, --share=ipc   the window
#   --talk-name=org.freedesktop.secrets       passwords in the system keychain
#   --talk-name=org.freedesktop.Notifications new-mail notifications
#   --filesystem=xdg-download          saving attachments to Downloads
# No access to the home folder; the file picker and links use portals.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly root
readonly id="com.fluminaris.citusmail"
readonly runtime="org.freedesktop.Platform"
readonly branch="25.08"
bundle="$root/app/build/linux/x64/release/bundle"
readonly bundle
[[ -x "$bundle/citusmail" ]] || { echo "error: build the Linux release bundle first" >&2; exit 1; }
version="$(sed -n 's/^version: *//p' "$root/app/pubspec.yaml" | cut -d+ -f1)"
readonly version

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/app"
repo="$work/repo"

# The runtime doubles as the "SDK": nothing is compiled.
flatpak build-init "$app" "$id" "$runtime" "$runtime" "$branch"
files="$app/files"
mkdir -p "$files/lib/citusmail" "$files/bin" "$files/share/applications" \
  "$files/share/metainfo" "$files/share/icons/hicolor/scalable/apps"
cp -a "$bundle/." "$files/lib/citusmail/"
ln -s ../lib/citusmail/citusmail "$files/bin/citusmail"
install -m 644 "$root/packaging/linux/$id.desktop" "$files/share/applications/"
install -m 644 "$root/packaging/linux/$id.metainfo.xml" "$files/share/metainfo/"
install -m 644 "$root/assets/icon/icon.svg" "$files/share/icons/hicolor/scalable/apps/$id.svg"
for size in 16 32 48 64 128 256 512; do
  install -d "$files/share/icons/hicolor/${size}x${size}/apps"
  install -m 644 "$root/assets/icon/png/$size.png" "$files/share/icons/hicolor/${size}x${size}/apps/$id.png"
done

flatpak build-finish "$app" \
  --command=citusmail \
  --share=network \
  --share=ipc \
  --socket=wayland \
  --socket=fallback-x11 \
  --device=dri \
  --talk-name=org.freedesktop.secrets \
  --talk-name=org.freedesktop.Notifications \
  --filesystem=xdg-download

flatpak build-export "$repo" "$app" stable
mkdir -p "$root/build/packages"
out="$root/build/packages/citusmail-$version.flatpak"
flatpak build-bundle --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
  "$repo" "$out" "$id" stable
echo "wrote $out"
