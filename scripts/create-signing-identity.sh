#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain for build.sh.
# Signing every build with the same certificate lets macOS keep the permissions granted to the
# app (Accessibility, microphone) instead of asking again after each rebuild.
set -euo pipefail

NAME="Dynamic Island Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
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
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 12)
# -legacy: macOS's `security import` can't read the newer PKCS#12 encryption of OpenSSL 3.
LEGACY=$(openssl version | grep -q "^OpenSSL 3" && echo "-legacy" || true)
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASS"
# -T: codesign may use the key without asking every time.
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

echo "Created \"$NAME\". Rebuild with scripts/build.sh, then grant the permissions once more."
