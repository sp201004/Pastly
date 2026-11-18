#!/bin/bash
# Creates a local, self-signed code-signing identity ("Pastly Local Signing") in its own keychain,
# .signing/pastly-signing.keychain-db (git-ignored). Every build signed with it has the same identity, so macOS
# keeps the Accessibility permission across rebuilds and updates. No Apple Developer account needed.
#
#   ./Scripts/create-signing-identity.sh          # asks for a new keychain password (input hidden)
#   PASTLY_SIGNING_PASSWORD=… ./Scripts/…          # or takes it from the environment
#
# The password is never written to disk or into this repository. Nothing is added to your login keychain. The new
# keychain is appended to your keychain search list (codesign only finds identities there); every keychain already on
# the list stays, in the same order. To undo: remove its path with `security list-keychains -d user -s …`.
# This is not a Developer ID: Gatekeeper still rejects the app on other Macs (see RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=.signing
KC="$PWD/$DIR/pastly-signing.keychain-db"
NAME="Pastly Local Signing"

if [ -f "$KC" ]; then echo "✓ Signing identity already exists ($KC)"; exit 0; fi

PW="${PASTLY_SIGNING_PASSWORD:-}"
if [ -z "$PW" ]; then
  [ -t 0 ] || { echo "✗ Set PASTLY_SIGNING_PASSWORD or run this in a terminal." >&2; exit 1; }
  read -r -s -p "New password for the signing keychain: " PW; echo
  read -r -s -p "Repeat the password: " PW2; echo
  [ "$PW" = "$PW2" ] || { echo "✗ The passwords don't match." >&2; exit 1; }
  unset PW2
fi
[ ${#PW} -ge 12 ] || { echo "✗ Use at least 12 characters." >&2; exit 1; }

mkdir -p "$DIR"; chmod 700 "$DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# macOS `security` only reads PKCS#12 files that use the older SHA-1/3DES encryption. The file exists only in a
# temporary folder, protected by a random one-time password.
P12_PW=$(openssl rand -hex 24); export P12_PW
P12_OPTS=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
if openssl version | grep -q "^OpenSSL 3"; then P12_OPTS+=(-legacy); fi
openssl pkcs12 -export "${P12_OPTS[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout env:P12_PW 2>/dev/null
rm -f "$TMP/key.pem"

# `security create-keychain` changes the user search list; set it to the previous list plus the new keychain.
SEARCH_LIST=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
  [ -n "$line" ] && SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)

security create-keychain -p "$PW" "$KC"
security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"} "$KC"
security set-keychain-settings "$KC"            # no auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12_PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
unset PW P12_PW
echo "✓ Created \"$NAME\" in $KC"
echo "  Keep the password in your password manager. To let builds unlock the keychain without asking, you can"
echo "  store it in your login keychain:  security add-generic-password -a \"\$USER\" -s \"Pastly signing keychain\" -w"
