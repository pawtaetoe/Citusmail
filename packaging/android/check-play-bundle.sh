#!/bin/bash
# Checks that a Google Play bundle (the "play" flavor) leaves Instant mail
# out and keeps the periodic mail check:
#
#   packaging/android/check-play-bundle.sh build/packages/citusmail-<version>.aab
#
# The bundle's manifest (base/manifest/AndroidManifest.xml) is a protocol
# buffer whose names and values are plain UTF-8 strings, so grep finds them.
set -euo pipefail

bundle="${1:?usage: $0 <bundle.aab>}"
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
unzip -p "$bundle" base/manifest/AndroidManifest.xml > "$manifest"

failed=0
has() { grep -aqF -- "$1" "$manifest"; }

# Things the Play build must not have (Play reviews specialUse by hand).
for gone in android.permission.FOREGROUND_SERVICE_SPECIAL_USE \
            com.fluminaris.citusmail.InstantMailService \
            com.fluminaris.citusmail.BootReceiver \
            PROPERTY_SPECIAL_USE_FGS_SUBTYPE \
            specialUse; do
  if has "$gone"; then
    echo "error: the Play bundle still has $gone" >&2
    failed=1
  else
    echo "ok: no $gone"
  fi
done

# Things it must keep: the app itself and WorkManager's periodic check.
for kept in com.fluminaris.citusmail.MainActivity \
            android.permission.INTERNET \
            android.permission.RECEIVE_BOOT_COMPLETED \
            androidx.work.impl.background.systemjob.SystemJobService \
            androidx.work.impl.background.systemalarm.RescheduleReceiver; do
  if has "$kept"; then
    echo "ok: has $kept"
  else
    echo "error: the Play bundle lacks $kept" >&2
    failed=1
  fi
done

exit "$failed"
