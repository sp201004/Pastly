#!/bin/bash
# Prints GitHub release notes for a version: its CHANGELOG.md section, install steps, the signing status and the
# checksum from build/Pastly.dmg.sha256. Paste the output into the GitHub release.
#   ./Scripts/release-notes.sh              # version from Resources/Info.plist
#   ./Scripts/release-notes.sh 0.7.0 > build/RELEASE_NOTES.md
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)}"
SUM="build/Pastly.dmg.sha256"

# The "## <version> — <date>" section, without its heading.
CHANGES=$(awk -v v="$VERSION" '
  /^## / { if (found) exit; if (index($0, "## " v " ") == 1 || $0 == "## " v) { found = 1; next } }
  found' CHANGELOG.md)
[ -n "$CHANGES" ] || { echo "✗ No section for $VERSION in CHANGELOG.md" >&2; exit 1; }

if [ -f "$SUM" ]; then
  HASH=$(cut -d" " -f1 "$SUM")
  [[ "$HASH" =~ ^[0-9a-f]{64}$ ]] || { echo "✗ $SUM doesn't contain a SHA-256" >&2; exit 1; }
  CHECKSUM="SHA-256 (\`Pastly.dmg\`): \`$HASH\`

Check it after downloading: \`shasum -a 256 -c Pastly.dmg.sha256\` (both files in the same folder). A matching checksum
shows the download is the file published here; it doesn't prove the app is safe."
else
  CHECKSUM="Run ./Scripts/release.sh first — no checksum yet."
fi

# Describe the signature that's actually on build/Pastly.app.
if [ -d build/Pastly.app ] && codesign -dv build/Pastly.app 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]\{10\}"; then
  SIGNING="The app is signed with a Developer ID certificate. Check RELEASING.md for the notarization status of this build."
elif [ -d build/Pastly.app ] && codesign -dv build/Pastly.app 2>&1 | grep -q "Signature=adhoc"; then
  SIGNING="The app has an ad-hoc signature (no certificate, no Apple Team ID); the DMG is unsigned."
else
  SIGNING="The app has a self-signed signature (no Apple Team ID); the DMG is unsigned."
fi

cat <<EOF
# Pastly $VERSION

A beautiful, native clipboard manager for macOS. Free, open source (MIT) and 100% local.

## What's new
$(echo "$CHANGES" | sed '/^[[:space:]]*$/d')

## Install
1. Download \`Pastly.dmg\` and \`Pastly.dmg.sha256\`, and optionally check the checksum (below).
2. Open the DMG and drag **Pastly** to **Applications**.
3. **First launch.** This build is **not notarized by Apple** (the project has no paid Apple Developer membership), so
   macOS blocks it the first time. Open Pastly, click **Done**, then go to **System Settings → Privacy & Security**,
   click **Open Anyway** next to the message about Pastly, and confirm. You only do this once.
4. Allow Pastly under **System Settings → Privacy & Security → Accessibility** so it can paste for you.

A new installation starts with an empty history, stored only on your Mac in \`~/Library/Application Support/Pastly\`.

## Requirements
Apple silicon Mac (M1 or newer) with macOS 14 Sonoma or newer. Intel Macs aren't supported.

## Signing
$SIGNING Nothing in this release is notarized, and Gatekeeper doesn't approve it until you choose Open Anyway.
See RELEASING.md for details.

## Checksum
$CHECKSUM
EOF
