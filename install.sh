#!/bin/bash
# Teebe installer — https://teebe.io
# Usage: curl -fsSL https://teebe.io/install.sh | bash
#
# Installs teebe.app into /Applications without the Gatekeeper "unverified
# developer" block. curl-downloaded files carry no com.apple.quarantine flag,
# so the app opens on first launch with no dialog. Sparkle handles updates after.
set -euo pipefail

REPO="klein-t/teebe"
APP="teebe.app"
DEST="/Applications"

echo "Fetching latest teebe release…"
# Pull the .zip asset URL from the latest release (zip name is versioned).
ZIP_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' \
  | head -1 | sed 's/.*"https/https/; s/"$//')

if [ -z "${ZIP_URL}" ]; then
  echo "error: could not find a .zip asset on the latest release" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading ${ZIP_URL##*/}…"
curl -fsSL "${ZIP_URL}" -o "${TMP}/teebe.zip"

echo "Unpacking…"
unzip -q "${TMP}/teebe.zip" -d "${TMP}"

# Locate the .app inside the archive (handles any nesting).
APP_PATH=$(find "${TMP}" -maxdepth 2 -name "${APP}" -type d | head -1)
if [ -z "${APP_PATH}" ]; then
  echo "error: ${APP} not found in archive" >&2
  exit 1
fi

# Replace any existing install.
if [ -d "${DEST}/${APP}" ]; then
  echo "Removing previous ${APP}…"
  rm -rf "${DEST}/${APP}"
fi

echo "Installing to ${DEST}…"
mv "${APP_PATH}" "${DEST}/"

# Belt-and-suspenders: strip quarantine in case anything set it.
xattr -dr com.apple.quarantine "${DEST}/${APP}" 2>/dev/null || true

echo "Launching teebe…"
open "${DEST}/${APP}"

echo "✓ teebe installed. Updates are handled automatically from here."
