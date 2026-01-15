#!/bin/bash
# Generate client certificate for etcd access (e.g., for kube-apiserver)
# Usage: ./gen-client-cert.sh <client-name> [ca-server-url]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="${SCRIPT_DIR}/../pki"
CERT_DIR="${PKI_DIR}/certs"

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILED=1

# Arguments
CLIENT_NAME="${1:-etcd-client}"
CA_SERVER="${2:-https://localhost:8888}"

CLIENT_CERT_DIR="${CERT_DIR}/clients"
mkdir -p "$CLIENT_CERT_DIR"

echo "=== Generating Client Certificate: ${CLIENT_NAME} ==="
echo ""

# Check if cfssl container is available
if ! docker ps --format '{{.Names}}' | grep -q '^cfssl$'; then
    echo "Starting cfssl container..."
    cd "${SCRIPT_DIR}/.."
    PKI_DIR="$PKI_DIR" CERT_DIR="$CERT_DIR" docker compose -f docker-compose.cfssl.yml up -d
    sleep 2
fi

# Function to run cfssl commands in container
cfssl_exec() {
    docker exec cfssl "$@"
}

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
    cfssl_exec cfssl genkey "/pki/client-${CLIENT_NAME}-csr.json" | \
        docker exec -i cfssl cfssljson -bare "/certs/clients/${CLIENT_NAME}"
    
    cfssl_exec cfssl sign \
        -remote "${CA_SERVER}" \
        -label "etcd-intermediate-ca" \
        -profile "client" \
        "/certs/clients/${CLIENT_NAME}.csr" | \
        docker exec -i cfssl cfssljson -bare "/certs/clients/${CLIENT_NAME}"
else
    cfssl_exec cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -profile client \
        "/pki/client-${CLIENT_NAME}-csr.json" | \
        docker exec -i cfssl cfssljson -bare "/certs/clients/${CLIENT_NAME}"
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
