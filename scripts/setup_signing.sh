#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity so Murmur keeps a
# constant code identity across rebuilds. macOS ties the Accessibility grant to
# that identity, so granting once survives every future update — no more
# re-granting after each reinstall.
#
# Run this ONCE (it may prompt for your login keychain password):
#   bash scripts/setup_signing.sh
# Then rebuild: bash scripts/build_app.sh  (it auto-detects the identity).
#
# Remove later with: scripts/setup_signing.sh --remove
set -euo pipefail

NAME="Murmur Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "${1:-}" = "--remove" ]; then
  security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  security delete-certificate -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  echo "removed '$NAME'"; exit 0
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  echo "identity '$NAME' already present — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "[sign] generating self-signed code-signing cert"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1
# legacy PKCS12 encryption so macOS Security can import it
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:murmur -name "$NAME" \
  -legacy -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "[sign] importing into login keychain"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P murmur -T /usr/bin/codesign -A

# Critical: let codesign use the key without an interactive prompt.
# This needs the login keychain password.
echo "[sign] granting codesign access to the key (enter your login keychain password if asked)"
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
  || security set-key-partition-list -S apple-tool:,apple: "$KEYCHAIN" 2>/dev/null \
  || echo "[sign] note: if codesign still prompts, run Keychain Access and set the key to 'Allow all applications'."

echo
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  echo "✓ '$NAME' ready. Rebuild with: bash scripts/build_app.sh"
else
  echo "△ Imported, but not listed as a codesigning identity yet. Open Keychain"
  echo "  Access → find '$NAME' → right-click the private key → 'Get Info' →"
  echo "  Access Control → 'Allow all applications to access this item'. Then rebuild."
fi
