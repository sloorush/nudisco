#!/usr/bin/env bash
# Generate a self-signed cert for the optional HTTPS mode.
# Usage:  npm run gen-cert          # auto-detect this Mac's LAN IP
#         npm run gen-cert -- 192.168.1.50   # or pass it explicitly
#
# Writes certs/key.pem and certs/cert.pem. The cert's SubjectAltName includes
# your LAN IP so https://<ip>:PORT validates. You still have to TRUST it once on
# each phone (see the README "HTTPS mode" section).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="$DIR/certs"
mkdir -p "$CERT_DIR"

IP="${1:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)}"
echo "Generating self-signed certificate for IP $IP (+ localhost) …"

CONF="$(mktemp)"
cat > "$CONF" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = nudisco-$IP
[v3]
subjectAltName = IP:$IP, IP:127.0.0.1, DNS:localhost
basicConstraints = critical, CA:TRUE
keyUsage = digitalSignature, keyCertSign
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -days 365 \
  -config "$CONF"

rm -f "$CONF"

echo ""
echo "Wrote:"
echo "  $CERT_DIR/cert.pem   (share/trust this one on phones)"
echo "  $CERT_DIR/key.pem"
echo ""
echo "Now start HTTPS:  npm run start:https"
echo "Phones open:      https://$IP:<port>/   (then trust the cert — see README)"
