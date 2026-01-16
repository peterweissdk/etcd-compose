#!/bin/bash
# Generate client certificate for etcd access (e.g., for kube-apiserver)
# Usage: ./gen-client-cert.sh <client-name> [ca-server-url]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="${SCRIPT_DIR}/../pki"
CERT_DIR="${PKI_DIR}/certs"
BIN_DIR="${SCRIPT_DIR}/../bin"

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILED=1

# Check if cfssl is installed, if not download it
check_cfssl() {
    if [ ! -x "${BIN_DIR}/cfssl" ] || [ ! -x "${BIN_DIR}/cfssljson" ]; then
        echo "cfssl tools not found. Installing..."
        "${SCRIPT_DIR}/install-cfssl.sh" "$BIN_DIR"
    fi
}

# cfssl command wrapper
cfssl() {
    "${BIN_DIR}/cfssl" "$@"
}

# cfssljson command wrapper
cfssljson() {
    "${BIN_DIR}/cfssljson" "$@"
}

# Arguments
CLIENT_NAME="${1:-etcd-client}"
CA_SERVER="${2:-https://localhost:8888}"

CLIENT_CERT_DIR="${CERT_DIR}/clients"
mkdir -p "$CLIENT_CERT_DIR"

echo "=== Generating Client Certificate: ${CLIENT_NAME} ==="
echo ""

# Ensure cfssl is available
check_cfssl

# Check if multirootca is running
use_remote=false
if docker ps --format '{{.Names}}' | grep -q '^multirootca$'; then
    use_remote=true
    echo "Using multirootca server for signing..."
else
    echo "Using local CA files for signing..."
fi

# Create client CSR JSON dynamically
cat > "${PKI_DIR}/client-${CLIENT_NAME}-csr.json" <<EOF
{
  "CN": "${CLIENT_NAME}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "etcd",
      "OU": "etcd Client"
    }
  ]
}
EOF

# Generate client certificate
echo "Generating client certificate..."
if [ "$use_remote" = true ]; then
    cfssl genkey "${PKI_DIR}/client-${CLIENT_NAME}-csr.json" | \
        cfssljson -bare "${CLIENT_CERT_DIR}/${CLIENT_NAME}"
    
    cfssl sign \
        -remote "${CA_SERVER}" \
        -label "etcd-intermediate-ca" \
        -profile "client" \
        "${CLIENT_CERT_DIR}/${CLIENT_NAME}.csr" | \
        cfssljson -bare "${CLIENT_CERT_DIR}/${CLIENT_NAME}"
else
    cfssl gencert \
        -ca "${PKI_DIR}/intermediate-ca.pem" \
        -ca-key "${PKI_DIR}/intermediate-ca-key.pem" \
        -config "${PKI_DIR}/ca-config.json" \
        -profile client \
        "${PKI_DIR}/client-${CLIENT_NAME}-csr.json" | \
        cfssljson -bare "${CLIENT_CERT_DIR}/${CLIENT_NAME}"
fi

# Copy CA chain
cp "${PKI_DIR}/ca-chain.pem" "${CLIENT_CERT_DIR}/"

# Set permissions
chmod 644 "${CLIENT_CERT_DIR}"/*.pem 2>/dev/null || true
chmod 600 "${CLIENT_CERT_DIR}"/*-key.pem 2>/dev/null || true

echo ""
echo "=== Client Certificate Generated ==="
echo ""
echo "Files created in ${CLIENT_CERT_DIR}:"
ls -la "${CLIENT_CERT_DIR}/${CLIENT_NAME}"*.pem 2>/dev/null || echo "No .pem files found"
echo ""
echo "For Kubernetes kube-apiserver, copy these files:"
echo "  - ${CLIENT_CERT_DIR}/${CLIENT_NAME}.pem -> /etc/kubernetes/pki/apiserver-etcd-client.crt"
echo "  - ${CLIENT_CERT_DIR}/${CLIENT_NAME}-key.pem -> /etc/kubernetes/pki/apiserver-etcd-client.key"
echo "  - ${CLIENT_CERT_DIR}/ca-chain.pem -> /etc/kubernetes/pki/etcd/ca.crt"

exit $EXIT_SUCCESS
