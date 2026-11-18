#!/bin/bash
# Builds build/Pastly.app (Release) and build/Pastly.dmg for installing on another Mac.
# Repeatable: run it whenever you need a fresh DMG.
#
#   ./Scripts/release.sh
#
# Signing / notarization (Apple: "Notarizing macOS software before distribution"):
#   • If a "Developer ID Application" certificate is installed (or DEVELOPER_ID is set), the app is
#     signed with it (hardened runtime + secure timestamp) and the DMG is signed too.
#   • If notarization credentials are saved as a notarytool keychain profile
#     (NOTARY_PROFILE, default "pastly-notary"), both are notarized and stapled.
#       xcrun notarytool store-credentials pastly-notary --apple-id … --team-id … --password …
#   • Otherwise the app keeps the signature from the normal build (Scripts/build.sh), the DMG is left
#     unsigned, nothing is notarized, and the report says so. Quarantine and Gatekeeper are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Pastly.app"
DMG="build/Pastly.dmg"
STAGE="build/dmg-staging"
VOLNAME="Pastly"
PROFILE="${NOTARY_PROFILE:-pastly-notary}"

# ---------- 1. Developer ID available? ----------
if [ -z "${DEVELOPER_ID:-}" ]; then
  DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -n "$DEVELOPER_ID" ] && ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
  echo "✗ DEVELOPER_ID is set but not installed: $DEVELOPER_ID"; exit 1
fi

# ---------- 2. Build the app (Release) ----------
if [ -n "$DEVELOPER_ID" ]; then
  echo "▸ Developer ID found: $DEVELOPER_ID"
  SIGN_ID="$DEVELOPER_ID" ./Scripts/build.sh
else
  echo "▸ No Developer ID certificate installed — building with the normal development signing."
  ./Scripts/build.sh
fi
[ -d "$APP" ] || { echo "✗ $APP was not created"; exit 1; }
codesign --verify --strict --verbose=2 "$APP"

notarize() {   # $1 = .zip or .dmg
  local out id status
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
  id=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
  status=$(printf '%s' "$out" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  if [ "$status" != "Accepted" ]; then
    echo "✗ Notarization $status (submission $id):"; xcrun notarytool log "$id" --keychain-profile "$PROFILE"; exit 1
  fi
  echo "✓ Notarized ($(basename "$1"), submission $id)"
}

CAN_NOTARIZE=0
if [ -n "$DEVELOPER_ID" ] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  CAN_NOTARIZE=1
fi

# ---------- 3. Notarize + staple the app (only with real credentials) ----------
if [ $CAN_NOTARIZE -eq 1 ]; then
  echo "▸ Notarizing the app…"
  ZIP="build/Pastly-notarize.zip"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"; rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# ---------- 4. Create the DMG (UDZO, app + Applications shortcut) ----------
echo "▸ Creating ${DMG}…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Pastly.app"            # ditto keeps signatures, attributes and permissions
ln -s /Applications "$STAGE/Applications"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
sed "s/{{VERSION}}/$VERSION/g" Resources/DMG-ReadMe.txt > "$STAGE/Read Me — Setup Guide.txt"   # setup steps for testers
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
# The "custom icon" flag must be set on the mounted volume itself (hdiutil -srcfolder drops it),
# so build a writable image first, flag its root, then compress it.
RW="build/Pastly-rw.dmg"
rm -f "$RW"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
RWMNT=$(mktemp -d /tmp/pastly-rw.XXXXXX)
hdiutil attach "$RW" -readwrite -noverify -nobrowse -mountpoint "$RWMNT" >/dev/null
SetFile -a C "$RWMNT" 2>/dev/null || echo "⚠ SetFile unavailable — the DMG uses the generic disk icon"
sync; hdiutil detach "$RWMNT" -quiet; rmdir "$RWMNT" 2>/dev/null || true
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [ $CAN_NOTARIZE -eq 1 ]; then
    echo "▸ Notarizing the DMG…"; notarize "$DMG"; xcrun stapler staple "$DMG"
  fi
fi

# ---------- 5. Checksum (attach both files to the GitHub release) ----------
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

# ---------- 5. Verify ----------
echo
echo "▸ Verifying…"
MNT=$(mktemp -d /tmp/pastly-dmg.XXXXXX)
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MNT" >/dev/null
trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true' EXIT
check() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; FAILED=1; fi; }
FAILED=0
check "DMG mounts (volume \"$VOLNAME\")"                  "[ -d '$MNT' ] && diskutil info '$MNT' 2>/dev/null | grep -q 'Volume Name: *$VOLNAME'"
check "Pastly.app is inside the DMG"                  "[ -x '$MNT/Pastly.app/Contents/MacOS/Pastly' ]"
check "Applications shortcut points to /Applications"     "[ \"\$(readlink '$MNT/Applications')\" = /Applications ]"
check "Setup guide is included (Read Me — Setup Guide.txt)" "grep -q 'Pastly $VERSION — Setup Guide' '$MNT/Read Me — Setup Guide.txt'"
check "App in the DMG has an intact signature"            "codesign --verify --strict '$MNT/Pastly.app' 2>/dev/null"
check "App in the DMG is identical to build/Pastly.app" "diff -rq '$APP' '$MNT/Pastly.app' >/dev/null"
check "Volume uses the Pastly icon"                   "cmp -s '$MNT/.VolumeIcon.icns' Resources/AppIcon.icns && GetFileInfo -aC '$MNT' 2>/dev/null | grep -q 1"
check "SHA-256 checksum file matches the DMG"            "(cd \"$(dirname "$DMG")\" && shasum -a 256 -c \"$(basename "$DMG").sha256\" >/dev/null)"
check "No clipboard history, database or backup inside"   "[ -z \"\$(find '$MNT' \\( -iname '*.sqlite*' -o -iname '*-wal' -o -iname '*-shm' -o -iname '*.db' -o -iname '*.pastly' -o -iname '*.pastestash' -o -iname '*.plist' ! -path '*/Contents/Info.plist' \\) -print 2>/dev/null)\" ]"
hdiutil imageinfo "$DMG" | grep -q "Format: UDZO" && echo "  ✓ Compressed UDZO format" || { echo "  ✗ Not UDZO"; FAILED=1; }

ARCHS=$(lipo -archs "$APP/Contents/MacOS/Pastly")
MINOS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
SIGKIND=$(codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc" && echo "ad-hoc" || echo "${AUTHORITY:-unknown}")
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
GK_APP=$(spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true)
GK_DMG=$(spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 || true)
STAPLED=$(xcrun stapler validate "$APP" >/dev/null 2>&1 && echo yes || echo no)

echo
echo "================ Pastly $VERSION — release report ================"
echo "DMG:            $(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "Architecture:   $ARCHS   (Apple silicon: $(echo "$ARCHS" | grep -qw arm64 && echo yes || echo no); Intel: $(echo "$ARCHS" | grep -qw x86_64 && echo yes || echo no))"
echo "Minimum macOS:  $MINOS"
echo "App signature:  $SIGKIND   (Team ID: ${TEAM:-none})"
echo "Developer ID:   $([ -n "$DEVELOPER_ID" ] && echo "$DEVELOPER_ID" || echo "not installed — app is NOT Developer ID signed")"
echo "SHA-256:        $(cut -d" " -f1 "$DMG.sha256")"
echo "DMG signature:  $(codesign -dv "$DMG" >/dev/null 2>&1 && echo signed || echo unsigned)"
echo "Notarized:      $([ $CAN_NOTARIZE -eq 1 ] && echo "yes (stapled: $STAPLED)" || echo "NO — no Developer ID and/or notarization credentials")"
echo "Gatekeeper app: $(echo "$GK_APP" | head -1)"
echo "Gatekeeper dmg: $(echo "$GK_DMG" | head -1)"
echo "======================================================================"
if [ $CAN_NOTARIZE -eq 0 ]; then
  echo "⚠ Not notarized: on another Mac, macOS will block the first launch until the user approves it"
  echo "  in System Settings → Privacy & Security → Open Anyway."
fi
[ $FAILED -eq 0 ] || { echo "✗ Some checks failed (see above)."; exit 1; }
