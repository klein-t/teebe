#!/bin/bash
# Build teebe and wrap the SPM executable in a proper macOS .app bundle so it
# launches with a Dock icon, menu bar, and window (and can be double-clicked).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"   # debug | release
APP="teebe.app"
LOGO="Sources/Teebe/Resources/teebe-logo.png"

# Version stamped into the bundle. CFBundleVersion is what Sparkle's comparator
# uses to decide whether an update is newer, so it MUST increase per release —
# CI passes the release tag (e.g. APP_VERSION=0.2.0). A static value would make
# every release look identical and Sparkle would never offer an update.
APP_VERSION="${APP_VERSION:-0.2.2}"
BUILD_NUMBER="${BUILD_NUMBER:-$APP_VERSION}"

# Sparkle auto-update config. Override via env in CI; the public key pairs with
# the EdDSA private key used to sign updates (see CONTRIBUTING.md). The feed is
# hosted on our own domain (teebe.io, served by the teebe-site GitHub Pages repo)
# so the URL baked into shipped binaries is host-independent. The .app zip
# enclosures it references still live on GitHub Releases. The publish-appcast
# workflow pushes each published release's appcast.xml to teebe-site.
SU_FEED_URL="${SU_FEED_URL:-https://teebe.io/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BINDIR/Teebe"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/teebe"

# Copy the SwiftPM resource bundle(s) into Contents/Resources. They MUST live
# under Contents/ — a code-signed .app rejects "unsealed contents in the bundle
# root", so the bundle can't sit at the app root (where Bundle.module would look).
# The app's Brand.resourceBundle probes Contents/Resources for them at runtime.
# SwiftPM stages each as <Product>_<Target>.bundle next to the built binary.
echo "==> copying SwiftPM resource bundles into Contents/Resources"
shopt -s nullglob
for b in "$BINDIR"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Embed Sparkle.framework (SwiftPM stages it next to the binary) and point the
# executable's runtime search path at the bundle's Frameworks dir.
echo "==> embedding Sparkle.framework"
cp -R "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/teebe" 2>/dev/null || true

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

cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS is happy launching it locally. Sign the embedded
# framework first (inside-out), then the app. Real distribution replaces "-"
# with a Developer ID identity + notarization (see CONTRIBUTING.md).
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> built $APP"
echo "    open it with:  open $APP"
