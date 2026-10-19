#!/bin/zsh
# Creates the "LocalFlow Code Signing" self-signed certificate in your login keychain and trusts it for
# code signing only. build.sh signs with it, which gives LocalFlow a stable identity: macOS keeps its
# Microphone, Input Monitoring, and Accessibility permissions across rebuilds. Without trust, macOS
# silently refuses the keyboard permissions.
set -euo pipefail
NAME="LocalFlow Code Signing"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "'$NAME' already exists and is trusted."
  exit 0
fi

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<EOF
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
EOF

if ! security find-certificate -c "$NAME" >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg" 2>/dev/null
  PW=$(openssl rand -hex 16)
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PW"
  security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
fi

security find-certificate -c "$NAME" -p > "$TMP/cert.pem"
echo "macOS will ask for your password to trust the certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "$NAME"
