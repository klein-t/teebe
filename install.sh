#!/bin/bash
# Teebe installer — https://teebe.io
# Usage: curl -fsSL https://teebe.io/install.sh | bash
#
# Installs teebe.app into /Applications without the Gatekeeper "unverified
# developer" block. curl-downloaded files carry no com.apple.quarantine flag,
# so the app opens on first launch with no dialog. Sparkle handles updates after.
#
# The download is fetched via https://dl.teebe.io, which records anonymous,
# aggregate install stats (app version, country, user-agent — never your IP)
# then redirects to the GitHub release asset. See https://teebe.io/privacy.html.
set -euo pipefail

REPO="klein-t/teebe"
APP="teebe.app"
DEST="/Applications"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading teebe…"
# Primary: through the download endpoint (counts the install). Falls back to a
# direct GitHub fetch if the endpoint is unreachable.
if ! curl -fsSL "https://dl.teebe.io" -o "${TMP}/teebe.zip"; then
  echo "Download endpoint unavailable, fetching from GitHub…"
  ZIP_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | head -1 | sed 's/.*"https/https/; s/"$//')
  [ -n "${ZIP_URL}" ] || { echo "error: could not find a .zip asset on the latest release" >&2; exit 1; }
  curl -fsSL "${ZIP_URL}" -o "${TMP}/teebe.zip"
fi

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

# Offer the Claude Code hook that powers low-power mode + instant notifications.
# Only when we can actually ask (a TTY): a piped `curl | bash` install defers to
# the in-app offer on first launch. Idempotent; a malformed settings.json is
# left untouched.
SETTINGS="${HOME}/.claude/settings.json"
if [ -r /dev/tty ] && command -v python3 >/dev/null 2>&1; then
  printf "Add the Claude Code hook for instant notifications + low-power mode? [Y/n] " > /dev/tty
  read -r REPLY < /dev/tty || REPLY="n"
  case "${REPLY}" in
    [nN]*) echo "Skipped — teebe will offer it on first launch." ;;
    *)
      python3 - "${SETTINGS}" <<'PYEOF' \
        || echo "note: couldn't update settings.json — teebe will offer the hook on launch"
import json, os, sys
path = sys.argv[1]
CHANNEL = "dev.teebe.agent"
CMD = "notifyutil -p " + CHANNEL
EVENTS = ["Stop", "Notification", "UserPromptSubmit"]
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)   # malformed -> raise -> file left untouched
hooks = settings.setdefault("hooks", {})
changed = False
for event in EVENTS:
    groups = hooks.setdefault(event, [])
    if any(CHANNEL in (h.get("command") or "")
           for g in groups for h in (g.get("hooks") or [])):
        continue
    groups.append({"hooks": [{"type": "command", "command": CMD}]})
    changed = True
if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".teebe-tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, sort_keys=True)
    os.replace(tmp, path)
    print("✓ Claude Code hook installed")
else:
    print("✓ Claude Code hook already present")
PYEOF
      ;;
  esac
fi

echo "Launching teebe…"
open "${DEST}/${APP}"

echo "✓ teebe installed. Updates are handled automatically from here."
