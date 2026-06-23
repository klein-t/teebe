#!/bin/bash
# Build teebe and wrap the SPM executable in a proper macOS .app bundle so it
# launches with a Dock icon, menu bar, and window (and can be double-clicked).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"   # debug | release
APP="teebe.app"
LOGO="Sources/Treebranch/Resources/teebe-logo.png"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Treebranch"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/teebe"

# Build a multi-resolution AppIcon.icns from the logo so it shows in Finder,
# the Dock, and the app switcher.
if [[ -f "$LOGO" ]]; then
  echo "==> generating AppIcon.icns"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size"        "$LOGO" --out "$ICONSET/icon_${size}x${size}.png"   >/dev/null
    sips -z "$((size*2))" "$((size*2))" "$LOGO" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>teebe</string>
  <key>CFBundleDisplayName</key><string>teebe</string>
  <key>CFBundleIdentifier</key><string>dev.teebe.app</string>
  <key>CFBundleExecutable</key><string>teebe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching it locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> built $APP"
echo "    open it with:  open $APP"
