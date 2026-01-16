#!/bin/bash
# Download and install cfssl tools
# Usage: ./install-cfssl.sh [install-dir]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${SCRIPT_DIR}/../bin}"
CFSSL_VERSION="1.6.5"

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "=== Installing cfssl tools ==="
echo "OS: $OS, Architecture: $ARCH"
echo "Install directory: $INSTALL_DIR"
echo ""

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download cfssl
echo "Downloading cfssl..."
curl -sL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_${OS}_${ARCH}" \
    -o "${INSTALL_DIR}/cfssl"
chmod +x "${INSTALL_DIR}/cfssl"

# Download cfssljson
echo "Downloading cfssljson..."
curl -sL "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_${OS}_${ARCH}" \
    -o "${INSTALL_DIR}/cfssljson"
chmod +x "${INSTALL_DIR}/cfssljson"

# Verify installation
echo ""
echo "Verifying installation..."
"${INSTALL_DIR}/cfssl" version
"${INSTALL_DIR}/cfssljson" -h 2>&1 | head -1 || true

echo ""
echo "=== cfssl tools installed successfully ==="
echo ""
echo "Tools installed in: $INSTALL_DIR"
echo "  - cfssl"
echo "  - cfssljson"
echo ""
echo "Add to PATH (optional):"
echo "  export PATH=\"\$PATH:${INSTALL_DIR}\""
