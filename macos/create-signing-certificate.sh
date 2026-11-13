#!/bin/bash
#
# Creates the self-signed code signing certificate for Teams Busy Light.app
# (run once). The same certificate keeps the signature stable across
# builds, so macOS keeps the permissions granted to the app after updates.
#
# Prints the values for the GitHub secrets MACOS_SIGNING_P12 and
# MACOS_SIGNING_PASSWORD. Keep the .p12 and its password; a new certificate
# makes macOS ask for the permissions again.

set -euo pipefail

NAME="Teams Busy Light"
OUT="${1:-$PWD/teams-busy-light-signing}"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

PASSWORD="$(openssl rand -base64 24)"
# 3DES/SHA-1 so "security import" on macOS can read it with LibreSSL and OpenSSL 3
openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASSWORD" -out "$OUT/signing.p12"
printf '%s' "$PASSWORD" > "$OUT/password.txt"
base64 < "$OUT/signing.p12" | tr -d '\n' > "$OUT/signing.p12.base64"
chmod 600 "$OUT"/*

echo "Created in $OUT:"
echo "  signing.p12          certificate and private key"
echo "  password.txt         its password"
echo "  signing.p12.base64   for the GitHub secret"
echo
echo "Set the GitHub secrets (in the repository folder):"
echo "  gh secret set MACOS_SIGNING_P12 < \"$OUT/signing.p12.base64\""
echo "  gh secret set MACOS_SIGNING_PASSWORD < \"$OUT/password.txt\""
echo
echo "Sign a local build with the same certificate:"
echo "  MACOS_SIGNING_P12=\"\$(cat \"$OUT/signing.p12.base64\")\" MACOS_SIGNING_PASSWORD=\"\$(cat \"$OUT/password.txt\")\" bash macos/build.sh"
