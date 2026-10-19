#!/bin/bash
# Create a stable, local, self-signed code-signing identity named
# "PhilipsTVMenubar Self-Signed" in the login keychain.
#
# Why: macOS ties the "Local Network" privacy permission to an app's code
# signature. Ad-hoc signatures change on every build, so the permission keeps
# resetting. Signing every build with ONE stable identity makes the permission
# stick. build.sh uses this identity automatically if it exists.
#
# Run once per Mac:  ./make-signing-cert.sh
set -e

NAME="PhilipsTVMenubar Self-Signed"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.cnf" >/dev/null 2>&1

# Import key + cert separately (more reliable than PKCS#12 on macOS).
security import "$TMP/key.pem"  -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -A >/dev/null 2>&1
security import "$TMP/cert.pem" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -A >/dev/null 2>&1

echo "Created code-signing identity '$NAME'."
echo "Now run ./build.sh — it will sign with this identity automatically."
echo "On first launch, grant the Local Network permission once; it will persist."
