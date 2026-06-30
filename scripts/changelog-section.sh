#!/usr/bin/env bash
# Print one version's section body from CHANGELOG.md — everything between the
# "## [VERSION]" heading and the next "## " heading, without the heading line
# itself. This is the single source the Release workflow uses for BOTH the GitHub
# release body and the Sparkle appcast release notes, so all surfaces stay in sync
# with CHANGELOG.md.
#
# Usage: scripts/changelog-section.sh <version> [changelog-path]
#   e.g. scripts/changelog-section.sh 0.3.0
set -euo pipefail

VERSION="${1:?usage: changelog-section.sh <version> [changelog-path]}"
CHANGELOG="${2:-CHANGELOG.md}"

awk -v ver="$VERSION" '
  /^## / {
    if (inSection) exit            # next version heading ends the section
    hdr = $0
    sub(/^## /, "", hdr)
    sub(/ - .*/, "", hdr)          # drop " - DATE"
    gsub(/[][ ]/, "", hdr)         # drop brackets and spaces -> bare version
    if (hdr == ver) { inSection = 1; next }
  }
  inSection { print }
' "$CHANGELOG" \
  | awk 'NF {seen=1} seen {print}' \
  | awk '{ lines[NR]=$0 } END { last=NR; while (last>0 && lines[last]=="") last--; for (i=1;i<=last;i++) print lines[i] }'
