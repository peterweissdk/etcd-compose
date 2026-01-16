## Alpha Release

### Planned Feature: etcd backup functionality.

# 💾 etcd Docker Compose

[![Static Badge](https://img.shields.io/badge/Docker-Compose-white?style=flat&logo=docker&logoColor=white&logoSize=auto&labelColor=black)](https://docker.com/)
[![Static Badge](https://img.shields.io/badge/etcd-white?style=flat&logo=etcd&logoColor=white&logoSize=auto&labelColor=black)](https://etcd.io)
[![Static Badge](https://img.shields.io/badge/Linux-white?style=flat&logo=linux&logoColor=white&logoSize=auto&labelColor=black)](https://www.linux.org/)
[![Static Badge](https://img.shields.io/badge/GPL-V3-white?style=flat&logo=gnu&logoColor=white&logoSize=auto&labelColor=black)](https://www.gnu.org/licenses/gpl-3.0.en.html/)

A streamlined setup for deploying an **etcd** distributed key-value store cluster using Docker Compose.

## ✨ Features

- **Interactive Setup** — Guided script for cluster configuration
- **Multi-node Support** — Configure 1-9 node clusters
- **TLS Encryption** — Secure communication between cluster nodes
- **PKI Infrastructure** — Built-in CA server using multirootca
- **Certificate Management** — Generate, renew, and manage certificates with cfssl
- **Container Management** — Create or reset etcd containers
- **Automatic Configuration** — Generates `.env` file with cluster settings
- **Retry Logic** — Automatic retry on container startup failures

## 🚀 Quick Start

### Standard Setup (no encryption)

1. **Run the setup script:**
   ```bash
   ./etcd-compose.sh
   ```

2. **Choose option 1** for standard setup without encryption

3. **Follow the prompts** to configure nodes, version, and token

### TLS Setup (recommended for production)

1. **Run the setup script:**
   ```bash
   ./etcd-compose.sh
   ```

2. **Choose option 2** for TLS-encrypted cluster

3. **The script will:**
   - Generate Root CA (valid for 10 years)
   - Generate Intermediate CA (valid for 8 years)
   - Start multirootca CA server on Node 1
   - Generate server and peer certificates
   - Start etcd with TLS enabled

4. **For additional nodes**, generate certificates:
   ```bash
   ./scripts/gen-node-certs.sh <node-name> <node-ip>
   ```

5. **For Kubernetes integration**, generate client certificate:
   ```bash
   ./scripts/gen-client-cert.sh kube-apiserver-etcd-client
   ```

## 🔧 Configuration

All configuration is stored in the `.env` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `ETCD_VERSION` | etcd Docker image version | `v3.6.0` |
| `TOKEN` | Cluster token (same on all nodes) | — |
| `CLUSTER_STATE` | `new` for initial setup, `existing` after | `new` |
| `REGISTRY` | Docker registry for etcd image | `gcr.io/etcd-development/etcd` |
| `DATA_DIR` | Host path for etcd data | `/var/lib/etcd` |
| `NAME_1`, `NAME_2`, ... | Node names | — |
| `HOST_1`, `HOST_2`, ... | Node IP addresses | — |
| `CLUSTER` | Cluster member URLs | Auto-generated |
| `TLS_ENABLED` | Enable TLS encryption | `false` |
| `PKI_DIR` | PKI directory path | `./pki` |
| `CERT_DIR` | Certificate directory on host | `/etc/etcd/pki` |

## 📝 Directory Structure

```
etcd-compose/
├── .env                     # Environment variables (generated)
├── docker-compose.yml       # Docker Compose service definition (no TLS)
├── docker-compose.tls.yml   # Docker Compose with TLS enabled
├── docker-compose.ca.yml    # Multirootca CA server
├── etcd-compose.sh          # Interactive setup script
├── LICENSE                  # GPL v3.0 license
├── README.md                # This file
├── bin/                     # cfssl binaries (auto-downloaded)
│   ├── cfssl                # Certificate generation tool
│   └── cfssljson            # JSON output processor
├── pki/                     # PKI configuration and certificates
│   ├── ca-config.json       # CFSSL signing profiles
│   ├── root-ca-csr.json     # Root CA CSR template
│   ├── intermediate-ca-csr.json  # Intermediate CA CSR template
│   ├── server-csr.json      # Server certificate template
│   ├── peer-csr.json        # Peer certificate template
│   ├── client-csr.json      # Client certificate template
│   ├── multirootca-config.json   # Multirootca configuration
│   └── certs/               # Generated certificates
└── scripts/                 # Helper scripts
    ├── install-cfssl.sh     # Download cfssl binaries
    ├── init-ca.sh           # Initialize CA infrastructure
    ├── gen-node-certs.sh    # Generate node certificates
    ├── gen-client-cert.sh   # Generate client certificates
    └── renew-certs.sh       # Check and renew certificates
```

## 🔐 TLS Architecture

```
┌─────────────────────────────────────────┐
│           Node 1 (CA Server)            │
│  ┌─────────────┐  ┌─────────────────┐   │
│  │ multirootca │  │      etcd       │   │
│  │   :8888     │  │  :2379/:2380    │   │
│  └─────────────┘  └─────────────────┘   │
└─────────────────────────────────────────┘
           │
           │ Sign certificates
           ▼
┌─────────────────┐  ┌─────────────────┐
│     Node 2      │  │     Node 3      │
│  ┌───────────┐  │  │  ┌───────────┐  │
│  │   etcd    │  │  │  │   etcd    │  │
│  │ :2379/80  │  │  │  │ :2379/80  │  │
│  └───────────┘  │  │  └───────────┘  │
└─────────────────┘  └─────────────────┘
```

### Certificate Hierarchy

- **Root CA** (10 years) — Offline, signs only intermediate CA
- **Intermediate CA** (8 years) — Signs server, peer, and client certs
- **Server/Peer Certs** (1 year) — Used by etcd nodes
- **Client Certs** (1 year) — Used by etcdctl, kube-apiserver

### Kubernetes Integration

For external etcd with Kubernetes, copy these files to the control plane:

```bash
# On control plane
mkdir -p /etc/kubernetes/pki/etcd

# Copy from etcd CA server
scp etcd-node:/path/to/pki/certs/clients/kube-apiserver-etcd-client.pem \
    /etc/kubernetes/pki/apiserver-etcd-client.crt
scp etcd-node:/path/to/pki/certs/clients/kube-apiserver-etcd-client-key.pem \
    /etc/kubernetes/pki/apiserver-etcd-client.key
scp etcd-node:/path/to/pki/ca-chain.pem \
    /etc/kubernetes/pki/etcd/ca.crt
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 🆘 Support

If you encounter any issues or need support, please file an issue on the GitHub repository.

## 📄 License

This project is licensed under the GNU GENERAL PUBLIC LICENSE v3.0 - see the [LICENSE](LICENSE) file for details.