#!/bin/bash
# Generate server and peer certificates for an etcd node
# Usage: ./gen-node-certs.sh <node-name> <node-ip> [ca-server-url]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="${SCRIPT_DIR}/../pki"
CERT_DIR="${PKI_DIR}/certs"

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILED=1

# Arguments
NODE_NAME="${1:-}"
NODE_IP="${2:-}"
CA_SERVER="${3:-https://localhost:8888}"

if [ -z "$NODE_NAME" ] || [ -z "$NODE_IP" ]; then
    echo "Usage: $0 <node-name> <node-ip> [ca-server-url]"
    echo ""
    echo "Arguments:"
    echo "  node-name     Name of the etcd node (e.g., etcd-1)"
    echo "  node-ip       IP address of the node (e.g., 192.168.1.10)"
    echo "  ca-server-url URL of the multirootca server (default: https://localhost:8888)"
    exit $EXIT_FAILED
fi

NODE_CERT_DIR="${CERT_DIR}/${NODE_NAME}"
mkdir -p "$NODE_CERT_DIR"

echo "=== Generating Certificates for ${NODE_NAME} ==="
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

# Check if multirootca is running (for remote signing)
use_remote=false
if docker ps --format '{{.Names}}' | grep -q '^multirootca$'; then
    use_remote=true
    echo "Using multirootca server for signing..."
else
    echo "Using local CA files for signing..."
fi

# Generate server certificate
echo ""
echo "Generating server certificate..."
if [ "$use_remote" = true ]; then
    # Generate key and CSR locally, sign remotely
    cfssl_exec cfssl genkey /pki/server-csr.json | \
        docker exec -i cfssl cfssljson -bare "/certs/${NODE_NAME}/server"
    
    cfssl_exec cfssl sign \
        -remote "${CA_SERVER}" \
        -label "etcd-intermediate-ca" \
        -profile "server" \
        -hostname "localhost,127.0.0.1,${NODE_NAME},${NODE_IP}" \
        "/certs/${NODE_NAME}/server.csr" | \
        docker exec -i cfssl cfssljson -bare "/certs/${NODE_NAME}/server"
else
    # Sign locally with intermediate CA
    cfssl_exec cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -hostname "localhost,127.0.0.1,${NODE_NAME},${NODE_IP}" \
        -profile server \
        /pki/server-csr.json | \
        docker exec -i cfssl cfssljson -bare "/certs/${NODE_NAME}/server"
fi
echo "Server certificate generated: ${NODE_CERT_DIR}/server.pem"

# Generate peer certificate
echo ""
echo "Generating peer certificate..."
if [ "$use_remote" = true ]; then
    cfssl_exec cfssl genkey /pki/peer-csr.json | \
        docker exec -i cfssl cfssljson -bare "/certs/${NODE_NAME}/peer"
    
    cfssl_exec cfssl sign \
        -remote "${CA_SERVER}" \
        -label "etcd-intermediate-ca" \
        -profile "peer" \
        -hostname "${NODE_NAME},${NODE_IP}" \
        "/certs/${NODE_NAME}/peer.csr" | \
        docker exec -i cfssl cfssljson -bare "/certs/${NODE_NAME}/peer"
else
    cfssl_exec cfssl gencert \
        -ca /pki/intermediate-ca.pem \
        -ca-key /pki/intermediate-ca-key.pem \
        -config /pki/ca-config.json \
        -hostname "${NODE_NAME},${NODE_IP}" \
        -profile peer \
        /pki/peer-csr.json | \
        docker exec -i cfssl cfssljson -bare "/certs/${NODE_NAME}/peer"
fi
echo "Peer certificate generated: ${NODE_CERT_DIR}/peer.pem"

# Copy CA chain to node cert directory
echo ""
echo "Copying CA chain..."
cp "${PKI_DIR}/ca-chain.pem" "${NODE_CERT_DIR}/"
echo "CA chain copied: ${NODE_CERT_DIR}/ca-chain.pem"

# Set permissions
echo ""
echo "Setting file permissions..."
chmod 644 "${NODE_CERT_DIR}"/*.pem 2>/dev/null || true
chmod 600 "${NODE_CERT_DIR}"/*-key.pem 2>/dev/null || true

echo ""
echo "=== Certificates Generated for ${NODE_NAME} ==="
echo ""
echo "Files created in ${NODE_CERT_DIR}:"
ls -la "${NODE_CERT_DIR}"/*.pem 2>/dev/null || echo "No .pem files found"
echo ""
echo "To use these certificates on the node:"
echo "1. Copy ${NODE_CERT_DIR}/* to the node's certificate directory"
echo "2. Update CERT_DIR in .env to point to the certificate directory"
echo "3. Use docker-compose.tls.yml to start etcd with TLS"

exit $EXIT_SUCCESS
