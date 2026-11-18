#!/bin/bash
# Builds build/Pastly.app (locally or ad-hoc signed, no Apple Developer account needed).
#   ./Scripts/build.sh            build the app
#   ./Scripts/build.sh --install  build and copy to /Applications
# For a release DMG use ./Scripts/release.sh (setup guide, checksum, verification).
# Set SIGN_ID="Your Certificate Name" to sign with a stable (e.g. self-signed) identity.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Pastly.app"
SIGN_ID="${SIGN_ID:--}"

echo "▸ Compiling (release)…"
swift build -c release

# The app icon is made from the Pastly logo (Resources/AppIcon.svg); regenerated whenever the logo changes.
if [ ! -f Resources/AppIcon.icns ] || [ Resources/AppIcon.svg -nt Resources/AppIcon.icns ]; then
  echo "▸ Generating icon from Resources/AppIcon.svg…"
  rm -rf build/AppIcon.iconset
  swift Scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Pastly" "$APP/Contents/MacOS/Pastly"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# Stable local identity (Scripts/create-signing-identity.sh) keeps macOS permissions across rebuilds.
# codesign only finds identities in keychains on your keychain search list; create-signing-identity.sh adds this one
# (keeping your other keychains), and --keychain makes sure the identity comes from it.
# The keychain password is never stored in this repository. It comes from, in this order:
#   1. PASTLY_SIGNING_PASSWORD (environment variable);
#   2. an optional login-keychain item:  security add-generic-password -a "$USER" -s "Pastly signing keychain" -w
#   3. a hidden prompt, when run in a terminal.
# Without it the build falls back to ad-hoc signing. Override the keychain or identity name with
# PASTLY_SIGNING_KEYCHAIN and PASTLY_SIGNING_IDENTITY.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Resources/Info.plist)
LOCAL_KC="${PASTLY_SIGNING_KEYCHAIN:-$PWD/.signing/pastly-signing.keychain-db}"
LOCAL_NAME="${PASTLY_SIGNING_IDENTITY:-Pastly Local Signing}"
case "$LOCAL_KC" in /*) ;; *) LOCAL_KC="$PWD/$LOCAL_KC" ;; esac
signed=0
if [ "$SIGN_ID" = "-" ] && [ -f "$LOCAL_KC" ]; then
  KC_PW="${PASTLY_SIGNING_PASSWORD:-}"
  [ -n "$KC_PW" ] || KC_PW=$(security find-generic-password -a "$USER" -s "Pastly signing keychain" -w 2>/dev/null || true)
  if [ -n "$KC_PW" ]; then
    security unlock-keychain -p "$KC_PW" "$LOCAL_KC" 2>/dev/null || echo "⚠ The signing keychain password was not accepted."
  elif [ -t 0 ]; then
    echo "▸ Unlock the local signing keychain ($(basename "$LOCAL_KC")) — input is hidden:"
    security unlock-keychain "$LOCAL_KC" || true
  fi
  unset KC_PW
  CERT_SHA1=$(security find-certificate -c "$LOCAL_NAME" -Z "$LOCAL_KC" 2>/dev/null | awk '/SHA-1/{print $NF}' | head -1 || true)
  KC_REAL="$(cd "$(dirname "$LOCAL_KC")" && pwd -P)/$(basename "$LOCAL_KC")"   # the search list holds resolved paths
  if ! security list-keychains -d user | grep -qF "$KC_REAL"; then
    echo "⚠ $(basename "$LOCAL_KC") isn't on your keychain search list, so codesign can't use it. To add it (keeps your"
    echo "  other keychains):  security list-keychains -d user -s \$(security list-keychains -d user | tr -d '\"') \"$LOCAL_KC\""
  fi
  if [ -n "$CERT_SHA1" ] && codesign --force --keychain "$LOCAL_KC" --sign "$CERT_SHA1" --timestamp=none \
       -r="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\"" "$APP" 2>/dev/null; then
    echo "▸ Signed with $LOCAL_NAME (permissions survive rebuilds)"
    signed=1
  else
    echo "⚠ Local signing identity \"$LOCAL_NAME\" not usable (keychain locked or identity missing) — falling back to ad-hoc."
    echo "  Ad-hoc builds lose the Accessibility permission on every rebuild. See README → Keep permissions."
  fi
fi
if [ $signed -eq 0 ] && [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then
  # Distribution signing for notarization (Apple's requirements): Developer ID certificate,
  # hardened runtime, secure timestamp. Pastly needs no extra entitlements.
  echo "▸ Signing for distribution (${SIGN_ID}, hardened runtime, secure timestamp)…"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  signed=1
fi
if [ $signed -eq 0 ]; then
  echo "▸ Signing (identity: ${SIGN_ID})…"
  codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications…"
  pkill -x Pastly 2>/dev/null || true
  rm -rf /Applications/Pastly.app
  cp -R "$APP" /Applications/
  echo "✓ Installed. Run: open /Applications/Pastly.app"
else
  echo "✓ $APP"
fi
