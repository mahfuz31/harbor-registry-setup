#!/usr/bin/env bash
#
# generate-cert.sh
# Generates a self-signed X.509 certificate with a Subject Alternative Name (SAN)
# extension for a Harbor registry host.
#
# Usage:
#   sudo ./generate-cert.sh <hostname> <lan-ip> [output-dir]
#
# Example:
#   sudo ./generate-cert.sh registry.example.com 192.168.1.50 /certs

set -euo pipefail

HOSTNAME="${1:?Usage: $0 <hostname> <lan-ip> [output-dir]}"
LAN_IP="${2:?Usage: $0 <hostname> <lan-ip> [output-dir]}"
OUT_DIR="${3:-/certs}"

echo "==> Creating output directory: ${OUT_DIR}"
mkdir -p "${OUT_DIR}"
cd "${OUT_DIR}"

echo "==> Generating 4096-bit RSA key + CSR for ${HOSTNAME}"
openssl req -newkey rsa:4096 -nodes -keyout registry.key \
  -out registry.csr \
  -subj "/C=US/L=City/O=YourOrg/CN=${HOSTNAME}"

echo "==> Writing SAN extension file"
cat <<EOF > registry.ext
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${HOSTNAME}
IP.1 = ${LAN_IP}
EOF

echo "==> Self-signing certificate (365 days)"
openssl x509 -req -days 365 -in registry.csr \
  -signkey registry.key -out registry.crt \
  -extfile registry.ext

echo "==> Done. Certificate files in ${OUT_DIR}:"
ls -la "${OUT_DIR}"/registry.*

echo ""
echo "Next steps:"
echo "  1. Reference ${OUT_DIR}/registry.crt and ${OUT_DIR}/registry.key in harbor.yml"
echo "  2. Distribute ${OUT_DIR}/registry.crt to every client machine (see docs/setup-guide.md Step 6B)"
