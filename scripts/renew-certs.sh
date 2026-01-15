#!/bin/bash
# Renew certificates before expiry
# Usage: ./renew-certs.sh [node-name] [ca-server-url]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKI_DIR="${SCRIPT_DIR}/../pki"
CERT_DIR="${PKI_DIR}/certs"

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILED=1

# Configuration
RENEW_BEFORE_DAYS=30
NODE_NAME="${1:-}"
CA_SERVER="${2:-https://localhost:8888}"

echo "=== Certificate Renewal Check ==="
echo ""

# Function to check certificate expiry
check_cert_expiry() {
    local cert_file="$1"
    local cert_name="$2"
    
    if [ ! -f "$cert_file" ]; then
        echo "Certificate not found: $cert_file"
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    
    if [ -z "$expiry_date" ]; then
        echo "Error reading certificate: $cert_file"
        return 1
    fi
    
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    echo "${cert_name}: ${days_left} days until expiry (${expiry_date})"
    
    if [ "$days_left" -lt "$RENEW_BEFORE_DAYS" ]; then
        echo "  ⚠ WARNING: Certificate expires in less than ${RENEW_BEFORE_DAYS} days!"
        return 2
    fi
    
    return 0
}

# Function to renew node certificates
renew_node_certs() {
    local node="$1"
    local node_ip="$2"
    
    echo ""
    echo "Renewing certificates for ${node}..."
    "${SCRIPT_DIR}/gen-node-certs.sh" "$node" "$node_ip" "$CA_SERVER"
}

# Check all certificates
needs_renewal=false

# Check CA certificates
echo "Checking CA certificates..."
check_cert_expiry "${PKI_DIR}/root-ca.pem" "Root CA" || true
check_cert_expiry "${PKI_DIR}/intermediate-ca.pem" "Intermediate CA" || true

# Check node certificates
echo ""
echo "Checking node certificates..."
if [ -n "$NODE_NAME" ]; then
    # Check specific node
    NODE_CERT_DIR="${CERT_DIR}/${NODE_NAME}"
    if [ -d "$NODE_CERT_DIR" ]; then
        check_cert_expiry "${NODE_CERT_DIR}/server.pem" "${NODE_NAME} Server" || needs_renewal=true
        check_cert_expiry "${NODE_CERT_DIR}/peer.pem" "${NODE_NAME} Peer" || needs_renewal=true
    else
        echo "No certificates found for node: ${NODE_NAME}"
    fi
else
    # Check all nodes
    for node_dir in "${CERT_DIR}"/*/; do
        if [ -d "$node_dir" ] && [ "$(basename "$node_dir")" != "clients" ]; then
            node=$(basename "$node_dir")
            check_cert_expiry "${node_dir}/server.pem" "${node} Server" || needs_renewal=true
            check_cert_expiry "${node_dir}/peer.pem" "${node} Peer" || needs_renewal=true
        fi
    done
fi

# Check client certificates
echo ""
echo "Checking client certificates..."
for cert_file in "${CERT_DIR}/clients"/*.pem; do
    if [ -f "$cert_file" ] && [[ ! "$cert_file" =~ -key\.pem$ ]] && [[ ! "$cert_file" =~ ca-chain\.pem$ ]]; then
        client_name=$(basename "$cert_file" .pem)
        check_cert_expiry "$cert_file" "Client: ${client_name}" || needs_renewal=true
    fi
done

echo ""
if [ "$needs_renewal" = true ]; then
    echo "⚠ Some certificates need renewal!"
    echo ""
    echo "To renew node certificates:"
    echo "  ./scripts/gen-node-certs.sh <node-name> <node-ip>"
    echo ""
    echo "To renew client certificates:"
    echo "  ./scripts/gen-client-cert.sh <client-name>"
else
    echo "✓ All certificates are valid."
fi

exit $EXIT_SUCCESS
