#!/usr/bin/env bash
#
# Build the drag-to-install DMG that teebe.io links to
# (releases/latest/download/teebe-macos.dmg).
#
# Uses `dmgbuild`, which writes the window's .DS_Store settings directly
# (background, icon positions/size, and the hide-chrome flags) without driving
# Finder over AppleScript — so it builds deterministically on headless CI.
# The layout lives in scripts/dmg/settings.py; the grey background is rendered
# by scripts/dmg/make-bg.swift into scripts/dmg/dmg-background.png.
#
# Heads-up: on macOS 26 (Tahoe) Finder shows its toolbar/status bar on dmg
# windows regardless of the hide flags — an OS limitation. Older macOS honors
# them and shows a clean, chrome-less window.
#
# Usage: scripts/make-dmg.sh [path/to/teebe.app] [output.dmg]
set -euo pipefail

APP="${1:-teebe.app}"
OUT="${2:-teebe-macos.dmg}"
HERE="$(cd "$(dirname "$0")/dmg" && pwd)"

[ -d "$APP" ] || { echo "error: app bundle not found: $APP" >&2; exit 1; }

# dmgbuild is pure-Python; install on demand so this works locally and on CI.
# --break-system-packages is needed on PEP 668 "externally managed" Pythons (the
# Homebrew python3 on GitHub's macOS runners); combined with --user it installs
# into the user site without touching the system env, and is a harmless no-op on
# non-managed Pythons.
python3 -c 'import dmgbuild' 2>/dev/null \
  || pip3 install --user --quiet --break-system-packages dmgbuild

APP_ABS="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
rm -f "$OUT"
python3 -m dmgbuild \
  -s "$HERE/settings.py" \
  -D app="$APP_ABS" \
  -D bg="$HERE/dmg-background.png" \
  "teebe" "$OUT"

echo "built $OUT"
