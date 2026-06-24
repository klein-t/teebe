#!/usr/bin/env bash
#
# Build the branded, drag-to-install DMG that teebe.io links to
# (releases/latest/download/teebe-macos.dmg).
#
# The styled look — dark background, icon positions, hidden toolbar, icon
# size — is carried by a prebuilt .DS_Store (scripts/dmg/DS_Store) that was
# captured once with `create-dmg` on a Mac with a Finder GUI. We deliberately
# do NOT run create-dmg here: it drives Finder over AppleScript, which is
# flaky/unavailable on headless CI runners. Instead we reassemble a volume
# named exactly "teebe" with the same files, so Finder reapplies the saved
# layout on mount. This is fully deterministic and needs no GUI.
#
# To restyle: edit scripts/dmg/make-bg.swift, regenerate the background, then
# re-capture scripts/dmg/DS_Store from a `create-dmg` build (see make-bg.swift
# header). The committed DS_Store is named without a leading dot so .gitignore
# rules for .DS_Store don't drop it; we rename it on the volume at build time.
#
# Usage: scripts/make-dmg.sh [path/to/teebe.app] [output.dmg]
set -euo pipefail

APP="${1:-teebe.app}"
OUT="${2:-teebe-macos.dmg}"
VOLNAME="teebe"
HERE="$(cd "$(dirname "$0")/dmg" && pwd)"

[ -d "$APP" ] || { echo "error: app bundle not found: $APP" >&2; exit 1; }

STAGE="$(mktemp -d)/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
cp "$HERE/dmg-background.png" "$STAGE/.background/dmg-background.png"
cp "$HERE/DS_Store" "$STAGE/.DS_Store"

# Read-write volume from the staged tree (carries our .DS_Store), then convert
# to a compressed, read-only image for distribution.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
RW="$(mktemp -u).dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"

echo "built $OUT"
