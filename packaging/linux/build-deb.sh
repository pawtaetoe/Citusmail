#!/usr/bin/env bash
# Builds a .deb from the Linux release bundle.
#
#   (cd app && flutter build linux --release)
#   packaging/linux/build-deb.sh            # writes build/packages/citusmail_<version>_amd64.deb
#
# The app goes to /opt/citusmail (it is a self-contained Flutter bundle), with a
# /usr/bin/citusmail link, a desktop entry, icons and AppStream metadata.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly root
readonly id="com.fluminaris.citusmail"
bundle="$root/app/build/linux/x64/release/bundle"
readonly bundle
[[ -x "$bundle/citusmail" ]] || { echo "error: build the Linux release bundle first" >&2; exit 1; }

# 0.1.0+1 in pubspec.yaml -> Debian version 0.1.0-1
version="$(sed -n 's/^version: *//p' "$root/app/pubspec.yaml" | tr '+' '-')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] || { echo "error: bad version '$version'" >&2; exit 1; }
readonly version

out="$root/build/packages"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

install -d "$stage/opt/citusmail" "$stage/usr/bin" "$stage/DEBIAN" \
  "$stage/usr/share/applications" "$stage/usr/share/metainfo" \
  "$stage/usr/share/icons/hicolor/scalable/apps"
cp -a "$bundle/." "$stage/opt/citusmail/"
ln -s /opt/citusmail/citusmail "$stage/usr/bin/citusmail"
install -m 644 "$root/packaging/linux/$id.desktop" "$stage/usr/share/applications/"
install -m 644 "$root/packaging/linux/$id.metainfo.xml" "$stage/usr/share/metainfo/"
install -m 644 "$root/assets/icon/icon.svg" "$stage/usr/share/icons/hicolor/scalable/apps/$id.svg"
for size in 16 32 48 64 128 256 512; do
  install -d "$stage/usr/share/icons/hicolor/${size}x${size}/apps"
  install -m 644 "$root/assets/icon/png/$size.png" "$stage/usr/share/icons/hicolor/${size}x${size}/apps/$id.png"
done

installed_kb="$(du -sk "$stage" | cut -f1)"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: citusmail
Version: $version
Architecture: amd64
Maintainer: Citusmail developers <noreply@invalid>
Installed-Size: $installed_kb
Depends: libc6 (>= 2.35), libgtk-3-0t64 | libgtk-3-0, libsecret-1-0
Recommends: gnome-keyring | kwalletmanager
Section: mail
Priority: optional
Description: Private email, sorted on your device
 An open-source mail app with no servers of its own and no analytics.
 Mail is stored encrypted, passwords stay in the system keychain, and
 remote images and trackers are blocked.
CONTROL

# Files owned by root, readable by all; nothing setuid.
find "$stage" -type d -exec chmod 755 {} +
mkdir -p "$out"
dpkg-deb --root-owner-group --build "$stage" "$out/citusmail_${version}_amd64.deb"
echo "wrote $out/citusmail_${version}_amd64.deb"
