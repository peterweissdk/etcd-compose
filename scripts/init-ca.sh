#!/bin/bash
# Initialize Root CA and Intermediate CA on Node 1
# This script should only be run once on the CA server node

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="${SCRIPT_DIR}/../pki"
CERT_DIR="${PKI_DIR}/certs"

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILED=1

echo "=== Initializing PKI Infrastructure ==="
echo ""

# Create directories
mkdir -p "$CERT_DIR"

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

# Generate Root CA (valid for 10 years = 87600h)
echo "Generating Root CA certificate (valid for 10 years)..."
if [ -f "${PKI_DIR}/root-ca.pem" ]; then
    echo "Root CA already exists. Skipping..."
else
    cfssl_exec cfssl gencert -initca /pki/root-ca-csr.json | \
        docker exec -i cfssl cfssljson -bare /pki/root-ca
    echo "Root CA generated: root-ca.pem, root-ca-key.pem"
fi

# Generate Intermediate CA (valid for 8 years = 70080h)
echo ""
echo "Generating Intermediate CA certificate (valid for 8 years)..."
if [ -f "${PKI_DIR}/intermediate-ca.pem" ]; then
    echo "Intermediate CA already exists. Skipping..."
else
    # Generate intermediate CA CSR
    cfssl_exec cfssl gencert -initca /pki/intermediate-ca-csr.json | \
        docker exec -i cfssl cfssljson -bare /pki/intermediate-ca-csr
    
    # Sign intermediate CA with root CA
    cfssl_exec cfssl sign \
        -ca /pki/root-ca.pem \
        -ca-key /pki/root-ca-key.pem \
        -config /pki/ca-config.json \
        -profile intermediate \
        /pki/intermediate-ca-csr.csr | \
        docker exec -i cfssl cfssljson -bare /pki/intermediate-ca
    
    echo "Intermediate CA generated: intermediate-ca.pem, intermediate-ca-key.pem"
fi

# Create CA chain (intermediate + root)
echo ""
echo "Creating CA chain certificate..."
cat "${PKI_DIR}/intermediate-ca.pem" "${PKI_DIR}/root-ca.pem" > "${PKI_DIR}/ca-chain.pem"
echo "CA chain created: ca-chain.pem"

# Generate CA server certificate for multirootca TLS
echo ""
echo "Generating CA server certificate for multirootca..."
if [ -f "${PKI_DIR}/ca-server.pem" ]; then
    echo "CA server certificate already exists. Skipping..."
else
    # Get the host IP from environment or prompt
    if [ -z "$CA_HOST" ]; then
        read -rp "Enter CA server hostname/IP: " CA_HOST
    fi
    
    cfssl_exec cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -hostname="localhost,127.0.0.1,${CA_HOST}" \
        -profile=server \
        /pki/server-csr.json | \
        docker exec -i cfssl cfssljson -bare /pki/ca-server
    
    echo "CA server certificate generated: ca-server.pem, ca-server-key.pem"
fi

# Set permissions
echo ""
echo "Setting file permissions..."
chmod 644 "${PKI_DIR}"/*.pem 2>/dev/null || true
chmod 600 "${PKI_DIR}"/*-key.pem 2>/dev/null || true

echo ""
echo "=== PKI Infrastructure Initialized ==="
echo ""
echo "Files created in ${PKI_DIR}:"
ls -la "${PKI_DIR}"/*.pem 2>/dev/null || echo "No .pem files found"
echo ""
echo "Next steps:"
echo "1. Start the multirootca server: docker compose -f docker-compose.ca.yml up -d"
echo "2. Generate node certificates using: ./scripts/gen-node-certs.sh <node-name> <node-ip>"

exit $EXIT_SUCCESS
